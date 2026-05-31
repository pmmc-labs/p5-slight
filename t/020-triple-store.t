
use v5.42;
use utf8;
use open ':std', ':encoding(UTF-8)';
use experimental qw[ class switch ];

use Slight;
use Slight::WorkingMemory;

my $sys  = Slight->new;
my $prog = $sys->compile(q[

(assert+ Bob   knows    Alice )
(assert+ Bob   knows    Chris )
(assert+ Chris knows    Bob   )
(assert+ Chris works-w/ Alice )
(assert+ Chris knows    Alice )
(assert+ Alice knows    Bob   )
(assert+ Alice knows    Chris )
(assert+ Alice works-w/ Chris )

(say (query? Alice :_       Chris ))
(say (query? :_    works-w/ Alice ))
(say (query? Bob   :_       :_    ))
(say (query? :_    :_       Chris ))

(say (retract! Alice knows Chris ))

(say (query? :_ :_ Chris ))

]);

my $prog_ctx = $sys->spawn_context( $prog );

my @halted = $sys->run;

foreach my $ctx (@halted) {
    my ($last) = $ctx->trace;
    say '-' x 40;
    if ($last isa Slight::Kontinue::Error) {
        say join ' ' => $last, $last->error;
    } else {
        say $last;
    }
    say "  - ", join "\n  - " => $last->env->chain;
}

__END__

;; local commits inside an actor
;; would look like this and commit
;; to the local working memory
(commit :message "Adding Bob and Chris stuff"
    (patch
        (assert! Bob   :knows    Alice )
        (assert! Bob   :knows    Chris )
        (assert! Chris :knows    Bob   )
        (assert! Chris :works-w/ Alice )
        (assert! Chris :knows    Alice )))


;; local queries

(let mutuals
    (where? (x)
        (and (x :knows Alice)
             (x :knows Chris))))

;; patches from other actors are sent
;; as merge requests messages
(send PID (merge-request
    :author     (getpid)
    :description "Adding Alice stuff"
    (patch
        (assert! Alice :knows    Bob   )
        (assert! Alice :knows    Chris )
        (assert! Alice :works-w/ Chris )
        (retract Chris :knows    Bob   ))))
