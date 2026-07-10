#!/usr/bin/env bash

set -euo pipefail

version="${1:?usage: update-highlights.sh <version> <section-file>}"
section_file="${2:?usage: update-highlights.sh <version> <section-file>}"
file="${CHANGELOG_FILE:-CHANGELOG.md}"
result_file="${UPDATE_RESULT_FILE:-}"

set_result() {
  if [ -n "$result_file" ]; then
    printf '%s\n' "$1" > "$result_file"
  fi
}

if [ ! -f "$file" ]; then
  echo "Highlights were preserved: changelog file not found: $file" >&2
  set_result preserved
  exit 0
fi

if [ ! -s "$section_file" ]; then
  echo "Highlights were preserved: generated section is empty" >&2
  set_result preserved
  exit 0
fi

tmp="$(mktemp "${file}.tmp.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
cp -p "$file" "$tmp"

set +e
perl - "$version" "$section_file" "$file" > "$tmp" <<'PERL'
use strict;
use warnings;

my ($version, $section_file, $file) = @ARGV;

sub read_raw {
  my ($path) = @_;
  open my $fh, '<:raw', $path or die "cannot read $path: $!\n";
  local $/;
  my $value = <$fh>;
  close $fh;
  return defined $value ? $value : '';
}

sub heading_version {
  my ($heading) = @_;
  $heading =~ s/(?:\r\n|\n)\z//;
  $heading =~ s/^##[ \t]+//;
  $heading =~ s/^\[//;
  $heading =~ s/\].*\z//;
  $heading =~ s/[ \t].*\z//;
  return $heading;
}

my $text = read_raw($file);
my $generated = read_raw($section_file);
my @headings;

while ($text =~ /^##[ \t]+[^\r\n]*(?:\r\n|\n|\z)/mg) {
  push @headings, [$-[0], $+[0], $&];
}

my $target_index = -1;
for my $index (0 .. $#headings) {
  if (heading_version($headings[$index][2]) eq $version) {
    $target_index = $index;
    last;
  }
}

exit 3 if $target_index < 0;

my ($section_start, $heading_end, $heading) = @{$headings[$target_index]};
my $section_end = $target_index < $#headings ? $headings[$target_index + 1][0] : length($text);
my $eol = $heading =~ /\r\n\z/ ? "\r\n" : $text =~ /\r\n/ ? "\r\n" : "\n";

$generated =~ s/\A[^\r\n]*(?:\r\n|\n|\z)//;
$generated =~ s/\A(?:\r\n|\n)+//;
$generated =~ s/(?:\r\n|\n)+\z//;
exit 4 if $generated eq '';
$generated =~ s/\r\n|\r|\n/$eol/g;

my $body = substr($text, $heading_end, $section_end - $heading_end);
my ($replace_start, $replace_end, $replacement);

if ($body =~ /^###[ \t]+Highlights[ \t]*(?:\r\n|\n|\z)/m) {
  $replace_start = $heading_end + $-[0];
  pos($body) = $+[0];
  if ($body =~ /^###[ \t]+/mg) {
    $replace_end = $heading_end + $-[0];
  } else {
    $replace_end = $section_end;
  }
  $replacement = "### Highlights${eol}${eol}${generated}${eol}${eol}";
} else {
  $replace_start = $heading_end;
  $replace_end = $heading_end;
  my $heading_has_eol = $heading =~ /(?:\r\n|\n)\z/;
  my $body_has_eol = $body =~ /\A(?:\r\n|\n)/;
  my $before = $heading_has_eol ? $eol : $eol . $eol;
  my $after = $body_has_eol ? $eol : $eol . $eol;
  $replacement = "${before}### Highlights${eol}${eol}${generated}${after}";
}

print substr($text, 0, $replace_start), $replacement, substr($text, $replace_end);
PERL
status=$?
set -e

case "$status" in
  0) ;;
  3)
    echo "Highlights were preserved: no changelog section found for v$version" >&2
    set_result preserved
    exit 0
    ;;
  4)
    echo "Highlights were preserved: generated section has no bullets" >&2
    set_result preserved
    exit 0
    ;;
  *)
    echo "failed to update Highlights for v$version" >&2
    exit "$status"
    ;;
esac

if cmp -s "$file" "$tmp"; then
  set_result unchanged
  echo "Highlights for v$version are already current" >&2
else
  mv "$tmp" "$file"
  set_result updated
  echo "Updated $file Highlights for v$version" >&2
fi
