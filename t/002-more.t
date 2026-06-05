
use v5.42;
use utf8;
use open ':std', ':encoding(UTF-8)';
use experimental qw[ class switch ];

use Slight;
use Slight::WorkingMemory;

my $sys    = Slight->new;
my $rqueue = $sys->run(q[

(let pid
    (fork
        (do
            (assert+ (getpid) :is 'STARTED)

            (defun loop () (do
                (let msg (recv))
                (if (eq? msg 'STOP)
                    (do
                        (retract! (getpid) :is 'STARTED)
                        (assert+  (getpid) :is 'STOPPED)
                        (say "... STOPPING")
                        (exit))
                    (do
                        (let q (query? (getpid) :is 'STARTED))
                        (if (nil? q)
                            (say "NOT STARTED")
                            (say "STARTED"))))
                (yield (loop))))

            (loop)
        )
    )
)

(send pid 'Hey)
(send pid 'STOP)
(send pid 'Yo) ;; <- dead letter

(waitpid pid)
(say "...done")

]);

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
