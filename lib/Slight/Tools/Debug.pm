package Slight::Tools::Debug;

use v5.42;
use utf8;
use open ':std', ':encoding(UTF-8)';
use experimental qw[ class switch ];

sub hex2rgb ($hex) {
    map hex, (substr($hex, 0, 2), substr($hex, 2, 2), substr($hex, 4, 2))
}

sub opcode2rgb ($op) {
    return hex2rgb("FCC200") if $op eq Slight::Machine::ERROR;
    return hex2rgb("5A4FCF") if $op eq Slight::Machine::HOST;
    return hex2rgb("00A86B") if $op eq Slight::Machine::JUST;
    return hex2rgb("4CBB17") if $op eq Slight::Machine::DROP;
    return hex2rgb("26619C") if $op eq Slight::Machine::COND;
    return hex2rgb("880085") if $op eq Slight::Machine::BIND;
    return hex2rgb("FFA343") if $op eq Slight::Machine::EVAL_EXPR;
    return hex2rgb("B784A7") if $op eq Slight::Machine::EVAL_HEAD;
    return hex2rgb("1C39BB") if $op eq Slight::Machine::EVAL_ARGS;
    return hex2rgb("8E3A59") if $op eq Slight::Machine::APPLY_EXPR;
    return hex2rgb("E25098") if $op eq Slight::Machine::APPLY_CALL;
    return hex2rgb("0F52BA") if $op eq Slight::Machine::ENTER_SCOPE;
    return hex2rgb("FFCC00") if $op eq Slight::Machine::LEAVE_SCOPE;
}

sub debug_queue ($tick, @queue) {
    say '─' x 120;
    say "QUEUE ╭",('─' x 113),"\n      ├─",
        (join "\n      ├─" =>
         map {
            my ($op, $env, @rest) = $_->@*;
            sprintf "\e[38;2;%s;m %-11s \e[38;2;%s;m %6s \e[0m %s" =>
                (join ';' => opcode2rgb($op)),
                $op,
                (join ';' => hex2rgb($env->hash)),
                substr($env->hash, 0, 6),
                join ', ' => @rest;

        }
        @queue),
        "\n      ╰",('─' x 113);
    say '─' x 120;
}

sub debug_step ($depth, $tick, $op, $env, @stack) {
    if ($tick == 1) {
        say sprintf "      ╭─────────────┬────────╮";
    }
    if ($op eq Slight::Machine::LEAVE_SCOPE) {
        say sprintf "%s      ╭─┴─────────────┴────────╯",
            ($depth ? ('  ' x $depth) : '');
    }
    if ($op eq Slight::Machine::ENTER_SCOPE && Slight::DEBUG < 2) {
        say sprintf "%s    ╰────────────────────────╮",
            ($depth ? ('  ' x $depth) : '');
    }
    say sprintf "%s\e[38;2;%s;m%05d \e[0m│\e[38;2;%s;m %-11s \e[0m│\e[38;2;%s;m %6s \e[0m│ %s",
        ($depth ? ('  ' x $depth) : ''),
        (join ';' => 120),
        $tick,
        (join ';' => opcode2rgb($op)),
        $op,
        (join ';' => hex2rgb($env->hash)),
        substr($env->hash, 0, 6),
        join ', ' => map $_->to_string, @stack;
    if ($op eq Slight::Machine::HOST) {
        say sprintf "      ╰─────────────┴────────╯";
    }
}

sub debug_bind ($depth, $tick, $name, $env, $local, %local) {
    my $indent = ($depth ? ('  ' x $depth) : '');
    say sprintf "${indent}\e[38;2;%s;m%05d \e[0m├%s╯" => (join ';' => 120), $tick, ('─' x 22);
    say sprintf "${indent}\e[38;2;%s;m%05d \e[0m│ BIND *%s" => (join ';' => 120), $tick, $name->to_string;
    say sprintf "${indent}\e[38;2;%s;m%05d \e[0m│  ╰─ENV (\e[38;2;%s;m%s\e[0m] -> \e[38;2;%s;m%s\e[0m)" =>
                    (join ';' => 120),
                    $tick,
                    (join ';' => hex2rgb($env->hash)),
                    substr($env->hash, 0, 6),
                    (join ';' => hex2rgb($local->hash)),
                    substr($local->hash, 0, 6);
    say sprintf "${indent}\e[38;2;%s;m%05d \e[0m│     +{%s : %s}" => (join ';' => 120), $tick, $_, $local{$_}
        foreach sort { $a cmp $b } keys %local;
    say sprintf "${indent}\e[38;2;%s;m%05d \e[0m├%s╮" => (join ';' => 120), $tick, ('─' x 22);
}

sub debug_call ($depth, $tick, $call, $env, $local, %local) {
    my $indent = ($depth ? ('  ' x $depth) : '');
    say sprintf "${indent}\e[38;2;%s;m%05d \e[0m├%s╯" => (join ';' => 120), $tick, ('─' x 22);
    say sprintf "${indent}\e[38;2;%s;m%05d \e[0m│ APPLY &%s" => (join ';' => 120), $tick, ($call->name // '__ANON__');
    say sprintf "${indent}\e[38;2;%s;m%05d \e[0m│  ╰─ENV (\e[38;2;%s;m%s\e[0m] -> \e[38;2;%s;m%s\e[0m)" =>
                    (join ';' => 120),
                    $tick,
                    (join ';' => hex2rgb($env->hash)),
                    substr($env->hash, 0, 6),
                    (join ';' => hex2rgb($local->hash)),
                    substr($local->hash, 0, 6);
    say sprintf "${indent}\e[38;2;%s;m%05d \e[0m│     +{%s : %s}" => (join ';' => 120), $tick, $_, $local{$_}
        foreach sort { $a cmp $b } keys %local;
    say sprintf "${indent}\e[38;2;%s;m%05d \e[0m╰%s╮" => (join ';' => 120), $tick, ('─' x 24);
}


