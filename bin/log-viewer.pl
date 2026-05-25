#!perl
use v5.42; use utf8; use open ':std', ':encoding(UTF-8)'; use Time::HiRes 'sleep';
while(defined(my $l = <>)) { sleep($ENV{CLOCK} // 0.03) if $l =~ /─*╮/; print $l }
