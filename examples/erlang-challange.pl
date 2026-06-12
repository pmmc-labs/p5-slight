
use v5.42;
use utf8;
use open ':std', ':encoding(UTF-8)';
use experimental qw[ class switch ];

use Time::HiRes qw[ gettimeofday tv_interval ];
use Memory::Stats;

use Slight;
use Slight::WorkingMemory;

my $fork_count = shift( @ARGV ) // 10;
my $source = qq[

(defun test-actor (next)
    (do
        (let msg (recv))
        (let count (cdar msg))
        (if (nil? next)
            (say "ALL DONE: " count)
            (send next (list 'PING (+ count 1)))
        )
    )
)

(defun setup (n next)
    (if (== n 0)
        (do
            (say "READY")
            next)
        (setup (- n 1) (fork (yield (test-actor next))))))

(say "INIT")
(let last (setup ${fork_count} (fork (yield (test-actor ())))))

(let start (gettimeofday))
(say "START")
(send last (list 'PING 0))

start

];

my $stats = Memory::Stats->new;

$stats->start;
my $begin   = [gettimeofday];
my $sys     = Slight->new;
my $start   = [gettimeofday];
$stats->checkpoint("pre-compile ");
my $exprs   = $sys->compile( $source );
my $compile = [gettimeofday];
$stats->checkpoint("pre-spawn   ");
my $ctx     = $sys->host->spawn_context($exprs);
$stats->checkpoint("pre-run     ");
my $rqueue  = $sys->host->run;
$stats->checkpoint("post-run    ");
my $end     = [gettimeofday];
$stats->stop;

my ($first) = grep { $ctx->pid->raw == $_->pid->raw } $rqueue->halted;
my $init = [ map $_->raw, (($first->trace)[0]->stack)[0]->uncons ];

my $total = tv_interval($begin, $end);
say sprintf 'RUNTIME: %.06f', $total;
say sprintf 'STARTUP: %.06f – %.02f%%', map { $_, (($_ / $total) * 100) } tv_interval($begin,   $start);
say sprintf 'COMPILE: %.06f – %.02f%%', map { $_, (($_ / $total) * 100) } tv_interval($start,   $compile);
say sprintf 'INITLIZ: %.06f – %.02f%%', map { $_, (($_ / $total) * 100) } tv_interval($compile, $init);
say sprintf 'EXECUTE: %.06f – %.02f%%', map { $_, (($_ / $total) * 100) } tv_interval($init,    $end);

$stats->report;

if ($ENV{DEBUG}) {
    say '=' x 40;
    say 'RESULTS:';
    foreach my $ctx ($rqueue->halted) {
        my ($last) = $ctx->trace;
        say '-' x 40;
        if ($last isa Slight::Kontinue::Error) {
            say sprintf '%s => %s %s' => $ctx->pid, $last, $last->error;
        } else {
            say sprintf '%s => %s' => $ctx->pid, $last;
        }
        say "  - ", join "\n  - " => $last->env->chain;
    }
    say '-' x 40;
    say 'ZOMBIES!';
    say "  - $_" foreach $rqueue->running;
    say '-' x 40;
    say 'BLOCKED!';
    say "  - $_" foreach $rqueue->blocked;
    say '-' x 40;
    say 'DEAD LETTERS!';
    say "  - $_" foreach $sys->host->dead_letters;
    say '-' x 40;
    say 'UNDELIVERED!';
    my %mb = $sys->host->mailboxes;
    say "  - $_" foreach map $_->@*, values %mb;
    say '=' x 40;
}

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
