
use v5.42;
use utf8;
use open ':std', ':encoding(UTF-8)';
use experimental qw[ class switch ];

use Time::HiRes qw[ sleep ];

use Slight;
use Slight::Tools::TUI;

my $r   = Slight::Runtime->new->init;
my $ctx = $r->spawn_context(q[

    (defun fact (n)
        (if (== n 0)
            (yield 1)
            (yield (* n (fact (- n 1))))))

    (defun fib (n)
        (if (< n 2)
            (yield n)
            (+ (yield (fib (- n 2)))
               (yield (fib (- n 1))))))

    (let pid1 (fork (yield (fib 4))))
    (let pid2 (fork (yield (fact 4))))

    (waitpid pid2)

]);

my sub hex2rgb ($hex) {
    map hex, (substr($hex, 0, 2), substr($hex, 2, 2), substr($hex, 4, 2))
}

my sub opcode2rgb ($op) {
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
    return hex2rgb("FFCC00") if $op eq Slight::Machine::ENTER_SCOPE;
    return hex2rgb("FCC2CC") if $op eq Slight::Machine::LEAVE_SCOPE;
}

my sub abbrev_env ($e) {
    sprintf '%s:{%s}' => substr($e->hash, 0, 6), (
        join ', ' => map {
            my $v = $e->local->{$_};
            join ': ' => $_, ucfirst((split /\:\:/ => blessed $v)[-1])
        }
        grep { !($e->local->{$_} isa Slight::Term::Procedure) }
        sort { $a cmp $b }
        keys $e->local->%*
    )
}

#$SIG{INT} = sub {
#    print
#        Slight::Tools::TUI::ANSI::show_cursor,
#        Slight::Tools::TUI::ANSI::disable_alt_buf;
#    die "Interuptted!";
#};
#
#print Slight::Tools::TUI::ANSI::enable_alt_buf;
#print Slight::Tools::TUI::ANSI::hide_cursor;
#
#$ctx->machine->watch(step => sub ($ctx, $event, $op, $env, @stack) {
#    print
#        Slight::Tools::TUI::ANSI::clear_screen,
#        Slight::Tools::TUI::ANSI::home_cursor
#        ;
#
#    say         '───────────╮';
#    say sprintf ' PROCESSES │ %s', join ' ╎ ' => map {
#        sprintf '%s %s(%03d)' =>
#            (refaddr $_ == refaddr $ctx
#                ? '▲'
#                : $_->is_halted
#                ? '●'
#                : $_->is_waiting
#                ? '◌'
#                : '▼'),
#            $_->PID,
#            $_->machine->tick
#    } $ctx->runtime->spawned;
#    say         '───────────┴', ('─' x 140);
#    say sprintf " -> \e[48;2;%d;%d;%d;m %-12s\e[0m %-100s \e[38;2;%d;%d;%d;m%-38s\e[0m" =>
#        opcode2rgb($op),
#        $op,
#        (join ', ' => map $_->to_string, @stack),
#        hex2rgb(substr($env->hash, 0, 6)),
#        abbrev_env($env);
#    if (my @queue = $ctx->machine->queue) {
#        say "  - ", join "\n  - " => map {
#            my ($_op, $_env, @_stack) = @$_;
#            sprintf "\e[48;2;%d;%d;%d;m %-12s\e[0m %-100s \e[38;2;%d;%d;%d;m%-38s\e[0m" =>
#                opcode2rgb($_op),
#                $_op,
#                (join ', ' => map $_->to_string, @_stack),
#                hex2rgb(substr($_env->hash, 0, 6)),
#                abbrev_env($_env), ;
#        } reverse @queue;
#    }
#
#    if ($ENV{D}) {
#        my $x = <>;
#    } else {
#        sleep($ENV{C} // 0.03);
#    }
#});

my @ctxs = $r->run;

say $_->result foreach @ctxs;

#print Slight::Tools::TUI::ANSI::show_cursor;
#print Slight::Tools::TUI::ANSI::disable_alt_buf if <>;

