
use v5.42;
use utf8;
use open ':std', ':encoding(UTF-8)';
use experimental qw[ class switch ];

use Slight;
use Slight::WorkingMemory;

my $sys    = Slight->new;
my $rqueue = $sys->run(q[

(defun set! (k op v)
    (do
        (let result (query? k := :_))
        (if (nil? result) () (retract! k := (.object (car result))))
        (assert+ k op v)))

(defun get! (k)
    (do
        (let result (query? k := :_))
        (if (nil? result) () (.object (car result)))))


(set! 'x := 10)
(say (get! 'x))
(set! 'x := 20)
(say (get! 'x))
(say (get! 'y))
(set! 'y := 10)
(say (get! 'y))

(say (+ (get! 'y) (get! 'x)))

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
