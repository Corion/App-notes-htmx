#!perl
use 5.020;
use experimental 'signatures';

use Test2::V0 '-no_srand';
use App::Notetaker::Document;

# YAML::Tiny::Dump sorts the keys of hashes, which is convenient for
# our test data
my $content = <<'__NOTE__';
---
links:
  - 'first link'
  - 'second link'
  - 'third link'
title: 'A test note'
---
Some test content
__NOTE__

my $note = App::Notetaker::Document->from_string($content,'testfile.markdown','/tmp');

my $note2 = App::Notetaker::Document->from_string($note->as_string(),'testfile.markdown','/tmp');
is $note2, $note, '->from_string and ->as_string return the same';
is $note2->as_string, $content, '->as_string returns the original note string';

$content = <<'__NOTE__';
---
labels:
  - bar
  - baz
  - foo
links:
  - 'first link'
  - 'second link'
  - 'third link'
title: 'A test note'
---
Some test content
__NOTE__

$note = App::Notetaker::Document->from_string($content,'testfile.markdown','/tmp');
$note2 = App::Notetaker::Document->from_string($note->as_string(),'testfile.markdown','/tmp');
is $note2, $note, '->from_string and ->as_string return the same, also with labels';
is $note2->as_string, $content, '->as_string returns the original note string';

done_testing;
