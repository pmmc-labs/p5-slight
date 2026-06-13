
use v5.42;
use utf8;
use open ':std', ':encoding(UTF-8)';
use experimental qw[ class switch ];

class Term {
    use overload '""' => 'to_string';
    method to_string { ... }
    method is_nil { false }
}

class Sym :isa(Term) {
    field $ident :param :reader;
    method to_string { $ident }
}

class Literal :isa(Term) {
    field $raw :param :reader;
    method to_string { "${raw}" }
}

class Str  :isa(Literal) {}
class Num  :isa(Literal) {}
class Bool :isa(Literal) {}

class Nil :isa(Term) {
    method to_string { '()' }
    method is_nil { true }
}
class Cons :isa(Term) {
    field $head :param :reader;
    field $tail :param :reader;

    method to_string { sprintf '(%s %s)' => $head->to_string, $tail->to_string }
}

class Native :isa(Term) {
    field $name :param :reader;
    field $proc :param :reader;

    method to_string { sprintf '#<%s>' => $name }
}

sub sym ($i) { Sym->new( ident => $i ) }
sub num ($n) { Num->new(   raw => $n ) }
sub str ($s) { Str->new(   raw => $s ) }

sub cons (@args) {
    my $list = Nil->new;
    while (@args) {
        $list = Cons->new( head => (pop @args), tail => $list );
    }
    return $list;
}

class Kontinue {
    use overload '""' => 'to_string';

    field $kont :param :reader = undef;
    field $env  :param :reader;

    method lookup ($sym) { $env->{ $sym->ident } }

    method to_string {
        sprintf '%s > %s', __CLASS__, defined $kont ? $kont->to_string : '';
    }
}

class Eval::Expr :isa(Kontinue) {
    field $expr :param :reader;

    method kontinue {
        say '-' x 120;
        say sprintf '=> %-12s : %-12s : %s' => __CLASS__, (caller)[0], $self->kont;
        say '-' x 120;
        say "  expr: ${expr}";
        given (blessed $expr) {
            when ('Cons') {
                return Eval::Expr->new(
                    env  => $self->env,
                    expr => $expr->head,
                    kont => Apply::Expr->new(
                        env  => $self->env,
                        args => $expr->tail,
                        kont => $self->kont,
                    )
                )
            }
            when ('Sym') {
                return $self->kont->kontinue( $self->lookup($expr) );
            }
            default {
                return $self->kont->kontinue( $expr );
            }
        }
    }
}

class Apply::Expr :isa(Kontinue) {
    field $args :param :reader;

    # 3a. creates Apply-Call with evaluated $head
    # 3b. creates Eval::Rest to evaluate $args
    method kontinue ($call) {
        say '-' x 120;
        say sprintf '=> %-12s : %-12s : %s' => __CLASS__, (caller)[0], $self->kont;
        say '-' x 120;
        say "  args: ${args}";
        say " +call: ${call}";
        Eval::Rest->new(
            env  => $self->env,
            rest => $args,
            kont => Apply::Call->new(
                env  => $self->env,
                call => $call,
                kont => $self->kont,
            )
        )
    }
}

class Eval::Rest :isa(Kontinue) {
    field $rest :param :reader;
    field $done :param :reader = +[];

    # 4. accumulate evaluates $args until nil and return to Apply-Call
    method kontinue (@evaled) {
        say '-' x 120;
        say sprintf '=> %-12s : %-12s : %s' => __CLASS__, (caller)[0], $self->kont;
        say '-' x 120;
        say "  rest: ${rest}";
        say "  done: ", join ', ' => map $_->to_string, @$done;
        say " +eval: ", join ', ' => map $_->to_string, @evaled;
        if ($rest->is_nil) {
            return $self->kont->kontinue( @$done, @evaled );
        } else {
            return Eval::Expr->new(
                env  => $self->env,
                expr => $rest->head,
                kont => Eval::Rest->new(
                    env  => $self->env,
                    rest => $rest->tail,
                    done => [ @$done, @evaled ],
                    kont => $self->kont,
                )
            )
        }
    }
}

class Apply::Call :isa(Kontinue) {
    field $call :param :reader;

    method kontinue (@args) {
        say '-' x 120;
        say sprintf '=> %-12s : %-12s : %s' => __CLASS__, (caller)[0], $self->kont;
        say '-' x 120;
        say "  call: ${call}";
        say " +args: ", join ', ' => map $_->to_string, @args;
        given (blessed $call) {
            when ('Native') {
                return $self->kont->kontinue( $call->proc->( @args ) );
            }
            default {
                # 5a. create new %ENV and bind $args to call parameters
                # 5b. create Scope-wrapped Eval-Expr with $call->body and new %ENV
                die "TODO"
            }
        }
    }
}

class Halt :isa(Kontinue) {
    field $result;

    method kontinue ($arg) {
        say join ' : ' => __CLASS__, $arg;
        $result = $arg;
        return undef;
    }
}

my %env = (
    '+' => Native->new( name => '+', proc => sub ($n, $m) { num($n->raw + $m->raw) }),
    '-' => Native->new( name => '-', proc => sub ($n, $m) { num($n->raw - $m->raw) }),
    '*' => Native->new( name => '*', proc => sub ($n, $m) { num($n->raw * $m->raw) }),
    '/' => Native->new( name => '/', proc => sub ($n, $m) { num($n->raw / $m->raw) }),
    '%' => Native->new( name => '%', proc => sub ($n, $m) { num($n->raw % $m->raw) }),
);


my $expr = cons( sym('+'),
    num(10), num(20)
    #cons( sym('-'), num(12), num(2) ),
    #cons( sym('*'), num(5), num(4) ),
);

say $expr;

my $halt = Halt->new( env => \%env );
my $next = Eval::Expr->new( env  => \%env, expr => $expr, kont => $halt );
while (defined($next = $next->kontinue)) {
    say "=" x 120;
}

























__END__


class Eval::Head :isa(Kontinue) {
    field $head :param :reader;
    field $rest :param :reader;

    # 2a. creates Apply-Expr with unevaled $rest
    # 2b. evaluates $head and returns it to Apply-Expr
    method kontinue {
        say '-' x 120;
        say sprintf '=> %-12s : %-12s : %s' => __CLASS__, (caller)[0], $self->kont;
        say '-' x 120;
        say "  head: ${head}";
        say "  rest: ${rest}";
        Eval::Expr->new(
            env  => $self->env,
            expr => $head,
            kont => Apply::Expr->new(
                env  => $self->env,
                args => $rest,
                kont => $self->kont,
            )
        )
    }
}
