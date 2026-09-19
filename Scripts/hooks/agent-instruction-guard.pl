#!/usr/bin/env perl
# Normalize Claude Write and Edit input plus Codex apply_patch input before checking the root budget.
use strict;
use warnings;
use utf8;

use Cwd qw(getcwd abs_path);
use Encode qw(decode encode);
use File::Basename qw(dirname);
use File::Spec;
use JSON::PP qw(decode_json encode_json);

binmode STDIN, ':raw';
binmode STDOUT, ':raw';

my $input_text = do { local $/; <STDIN> };
my $input = eval { decode_json($input_text) };
exit 0 unless ref $input eq 'HASH';

my $cwd = getcwd();
my $root = git_output($cwd, 'rev-parse', '--show-toplevel');
exit 0 unless defined $root && length $root;
$root = abs_path($root) // File::Spec->canonpath($root);

my %sizes = map { $_ => file_size(File::Spec->catfile($root, $_)) }
    qw(AGENTS.md AGENTS.override.md CLAUDE.md);
my ($changes, $error) = normalize_changes($input, $cwd, $root);
if ($error) {
    deny("The pending instruction edit could not be checked safely: $error");
    exit 0;
}

for my $change (@$changes) {
    apply_size_change(\%sizes, $change);
}

my $total = 0;
$total += $_ for values %sizes;
if ($total > 16384) {
    deny("Root guidance would be $total bytes, above the 16384 byte limit. Move detailed material to linked docs.");
}

sub normalize_changes {
    my ($payload, $workdir, $repo_root) = @_;
    my $tool = $payload->{tool_name} // '';
    my $tool_input = ref $payload->{tool_input} eq 'HASH' ? $payload->{tool_input} : {};
    my $command = $tool_input->{command};

    if (defined $command && $command =~ /\A\*\*\* Begin Patch(?:\r?\n|\z)/) {
        return parse_apply_patch($command, $workdir, $repo_root);
    }

    return ([], undef) unless $tool eq 'Write' || $tool eq 'Edit';
    my $path = $tool_input->{file_path} // '';
    return ([], undef) unless length $path;
    my ($abs, $rel) = resolve_path($path, $workdir, $repo_root);
    return ([], undef) unless is_instruction($rel);

    if ($tool eq 'Write') {
        return ([{ kind => 'write', target => $rel, size => byte_length($tool_input->{content} // '') }], undef);
    }

    my $current = read_text($abs);
    return ([], "cannot read $rel") unless defined $current;
    my $old = $tool_input->{old_string} // '';
    my $new = $tool_input->{new_string} // '';
    my $candidate = $current;
    if ($tool_input->{replace_all}) {
        $candidate =~ s/\Q$old\E/$new/g;
    } else {
        my $at = index($candidate, $old);
        return ([], "edit text was not found in $rel") if $at < 0;
        substr($candidate, $at, length($old), $new);
    }
    return ([{ kind => 'write', target => $rel, size => byte_length($candidate) }], undef);
}

sub parse_apply_patch {
    my ($command, $workdir, $repo_root) = @_;
    $command =~ s/\r\n/\n/g;
    my @lines = split /\n/, $command, -1;
    pop @lines while @lines && $lines[-1] eq '';
    return ([], 'missing patch header') unless @lines && shift(@lines) eq '*** Begin Patch';
    return ([], 'missing patch footer') unless @lines && pop(@lines) eq '*** End Patch';

    my @changes;
    while (@lines) {
        my $header = shift @lines;
        next if $header eq '';
        return ([], "unexpected patch line: $header")
            unless $header =~ /^\*\*\* (Add|Update|Delete) File: (.+)\z/;
        my ($kind, $source_path) = (lc($1), $2);
        my $target_path = $source_path;
        if ($kind eq 'update' && @lines && $lines[0] =~ /^\*\*\* Move to: (.+)\z/) {
            shift @lines;
            $target_path = $1;
        }

        my @body;
        push @body, shift @lines
            while @lines && $lines[0] !~ /^\*\*\* (?:Add|Update|Delete) File: /;
        my ($source_abs, $source_rel) = resolve_path($source_path, $workdir, $repo_root);
        my ($target_abs, $target_rel) = resolve_path($target_path, $workdir, $repo_root);
        next unless is_instruction($source_rel) || is_instruction($target_rel);

        if ($kind eq 'delete') {
            push @changes, { kind => 'delete', source => $source_rel, target => $target_rel };
            next;
        }

        my $delta = 0;
        my $added = 0;
        for my $line (@body) {
            if ($line =~ /^\+(.*)\z/) {
                my $bytes = byte_length($1) + 1;
                $delta += $bytes;
                $added += $bytes;
            } elsif ($line =~ /^-(.*)\z/) {
                $delta -= byte_length($1) + 1;
            }
        }

        if ($kind eq 'add') {
            push @changes, { kind => 'write', target => $target_rel, size => $added };
        } else {
            push @changes, {
                kind => 'update', source => $source_rel, target => $target_rel,
                source_size => file_size($source_abs), delta => $delta,
            };
        }
    }
    return (\@changes, undef);
}

sub apply_size_change {
    my ($sizes, $change) = @_;
    if ($change->{kind} eq 'delete') {
        $sizes->{$change->{source}} = 0 if is_instruction($change->{source});
        return;
    }
    if ($change->{kind} eq 'write') {
        $sizes->{$change->{target}} = $change->{size} if is_instruction($change->{target});
        return;
    }
    my $base = is_instruction($change->{source})
        ? ($sizes->{$change->{source}} // 0)
        : $change->{source_size};
    my $next = $base + $change->{delta};
    $next = 0 if $next < 0;
    if ($change->{source} ne $change->{target} && is_instruction($change->{source})) {
        $sizes->{$change->{source}} = 0;
    }
    $sizes->{$change->{target}} = $next if is_instruction($change->{target});
}

sub resolve_path {
    my ($path, $workdir, $repo_root) = @_;
    my $abs = File::Spec->file_name_is_absolute($path)
        ? File::Spec->canonpath($path)
        : File::Spec->canonpath(File::Spec->rel2abs($path, $workdir));
    $abs = real_path_with_missing_leaf($abs);
    my $rel = File::Spec->abs2rel($abs, $repo_root);
    $rel =~ s{\\}{/}g;
    return ($abs, $rel);
}

sub real_path_with_missing_leaf {
    my ($path) = @_;
    my @tail;
    my $cursor = $path;
    while (!-e $cursor) {
        my $parent = dirname($cursor);
        last if $parent eq $cursor;
        unshift @tail, File::Basename::basename($cursor);
        $cursor = $parent;
    }
    my $resolved = abs_path($cursor) // File::Spec->canonpath($cursor);
    return @tail ? File::Spec->catfile($resolved, @tail) : $resolved;
}

sub is_instruction {
    my ($rel) = @_;
    return defined $rel && ($rel eq 'AGENTS.md' || $rel eq 'AGENTS.override.md' || $rel eq 'CLAUDE.md');
}

sub read_text {
    my ($path) = @_;
    open my $file, '<:raw', $path or return undef;
    local $/;
    my $bytes = <$file>;
    return decode('UTF-8', $bytes);
}

sub file_size {
    my ($path) = @_;
    return -f $path ? -s $path : 0;
}

sub byte_length {
    my ($text) = @_;
    return length encode('UTF-8', $text // '');
}

sub git_output {
    my ($dir, @args) = @_;
    open my $pipe, '-|', 'git', '-C', $dir, @args or return undef;
    local $/;
    my $output = <$pipe>;
    close $pipe;
    return undef if $? != 0;
    $output =~ s/\s+\z//;
    return $output;
}

sub deny {
    my ($reason) = @_;
    print encode_json({
        hookSpecificOutput => {
            hookEventName => 'PreToolUse',
            permissionDecision => 'deny',
            permissionDecisionReason => $reason,
        },
    });
}
