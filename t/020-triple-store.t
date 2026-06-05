
use v5.42;
use utf8;
use open ':std', ':encoding(UTF-8)';
use experimental qw[ class switch ];

use Slight;
use Slight::WorkingMemory;

my $sys    = Slight->new;
my $rqueue = $sys->run(q[

(let Bob   '(Robert  Smith))
(let Alice '(Allison Chains))
(let Chris '(Chris   Kringle))

(assert+ Bob   :knows    Alice )
(assert+ Bob   :knows    Chris )
(assert+ Chris :knows    Bob   )
(assert+ Chris :works-w/ Alice )
(assert+ Chris :knows    Alice )
(assert+ Alice :knows    Bob   )
(assert+ Alice :knows    Chris )
(assert+ Alice :works-w/ Chris )

(say (query? Alice :_       Chris ))
(say (query? :_    :works-w/ Alice ))
(say (query? Bob   :_       :_    ))
(say (query? :_    :_       Chris ))

(say (retract! Alice :knows Chris ))

(say (query? :_ :_ Chris ))

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
