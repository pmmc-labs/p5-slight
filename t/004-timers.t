
use v5.42;
use utf8;
use open ':std', ':encoding(UTF-8)';
use experimental qw[ class switch ];

use Slight;
use Slight::WorkingMemory;

my $sys    = Slight->new;
my @halted = $sys->run(q[

(defun bouncer (timeout n)
    (do
        (if (== n 0)
            (do
                (say (~ "all done  ... " n " bounces in " (getpid)))
                (exit)
            )
            (do
                (say (~ "... bouncing " n " bounces in " (getpid)))
                (sleep timeout)
                (say (~ "bounced! " n " bounces in " (getpid)))
                (yield (bouncer timeout (- n 1)))
            )
        )
    )
)

(say "SO IT BEGINS")
(let p1 (fork (yield (bouncer 1 5))))
(sleep 3)
(let p2 (fork (yield (bouncer 1 3))))
(say "GETTING THERE")

(say "WHA!!!")

]);

say '=' x 40;
say 'RESULTS:';
foreach my $ctx (@halted) {
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
say "  - $_" foreach $sys->host->running;
say '-' x 40;
say 'BLOCKED!';
say "  - $_" foreach $sys->host->blocked;
say '-' x 40;
say 'DEAD LETTERS!';
say "  - $_" foreach $sys->host->dead_letters;
say '-' x 40;
say 'UNDELIVERED!';
my %mb = $sys->host->mailboxes;
say "  - $_" foreach map $_->@*, values %mb;
say '=' x 40;
