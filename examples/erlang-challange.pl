
use v5.42;
use utf8;
use open ':std', ':encoding(UTF-8)';
use experimental qw[ class switch ];

use Time::HiRes qw[ gettimeofday tv_interval ];

use Slight;
use Slight::WorkingMemory;

my $sys  = Slight->new;
my $prog = $sys->compile(q[

(defun test-actor (next)
    (do
        (let msg (recv))
        (say (~ (getpid) " got PING"))
        (if (nil? next)
            (say "THE END")
            (send next 'PING)
        )
    )
)

(defun setup (n next)
    (if (== n 0)
        (do
            (say "READY")
            next)
        (setup (- n 1) (fork (yield (test-actor next))))))

(say "START")
(let last (setup 10 (fork (yield (test-actor ())))))

(send last 'PING)


]);

my $prog_ctx = $sys->spawn_context( $prog );

my $start = [gettimeofday];
my @halted = $sys->run;
say tv_interval($start, [gettimeofday]);

#say '=' x 40;
#say 'RESULTS:';
#foreach my $ctx (@halted) {
#    my ($last) = $ctx->trace;
#    say '-' x 40;
#    if ($last isa Slight::Kontinue::Error) {
#        say sprintf '%s => %s %s' => $ctx->pid, $last, $last->error;
#    } else {
#        say sprintf '%s => %s' => $ctx->pid, $last;
#    }
#    say "  - ", join "\n  - " => $last->env->chain;
#}
#say '-' x 40;
#say 'ZOMBIES!';
#say "  - $_" foreach $sys->running;
#say '-' x 40;
#say 'BLOCKED!';
#say "  - $_" foreach $sys->blocked;
#say '-' x 40;
#say 'DEAD LETTERS!';
#say "  - $_" foreach $sys->dead_letters;
#say '-' x 40;
#say 'UNDELIVERED!';
#my %mb = $sys->mailboxes;
#say "  - $_" foreach map $_->@*, values %mb;
#say '=' x 40;

__END__

ErlangChallenge.io

Test := Object clone do(
    next ::= nil
    id ::= nil
    ping := method(
        //writeln("ping ", id)
        if(next, next @@ping)
        yield
    )
)

max := 10000

t := Test clone

setup := method(
    for(i, 1, max,
        t := Test clone setId(i) setNext(t)
        t @@id
        yield
    )
)

writeln(max, " coros")
writeln(Date secondsToRun(setup), " secs to setup")
writeln(Date secondsToRun(t ping; yield), " secs to ping")
