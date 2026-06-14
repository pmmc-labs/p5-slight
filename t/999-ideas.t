
use v5.42;
use utf8;
use open ':std', ':encoding(UTF-8)';
use experimental qw[ class switch ];

## -----------------------------------------------------------------------------

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

    method uncons {
        my @list;
        my $l = $self;
        until ($l->is_nil) {
            push @list => $l->head;
            $l = $l->tail;
        }
        return @list;
    }

    method to_string { sprintf '(%s)' => join ' ' => map $_->to_string, $self->uncons }
}

class Lambda :isa(Term) {
    field $params :param :reader;
    field $body   :param :reader;
    field $env    :param :reader;

    method is_operative   { false }
    method is_applicative { true  }

    method to_string { sprintf '(lambda %s %s)' => $params->to_string, $body->to_string }
}

class Native :isa(Term) {
    field $name :param :reader;
    field $proc :param :reader;

    field $is_operative :param :reader = false;
    method is_applicative { !$is_operative }

    method to_string { sprintf '#<%s>' => $name }
}

class Env {
    field $parent   :param :reader = undef;
    field $bindings :param :reader = +{};

    method lookup ($sym) {
        return $bindings->{ $sym->ident }
            // (defined $parent ? $parent->lookup($sym) : undef);
    }
}

## -----------------------------------------------------------------------------

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

sub append ($l, $r) { cons( $l->uncons, $r->uncons ) }

## -----------------------------------------------------------------------------

class Kontinue {
    use overload '""' => 'to_string';

    field $env  :param :reader;
    field $kont :param :reader = undef;

    method to_string {
        sprintf '%s > %s', __CLASS__, defined $kont ? $kont->to_string : '!!';
    }

    our $TICKS = 0;
    method DEBUG (@args) {
        say '-' x 120;
        say sprintf '=> %-12s : %-87s   %12s' => __CLASS__, $self->kont // '!!', (caller(1))[0], ;
        $TICKS++;
        say '-' x 120;
        foreach my ($name, $arg) (@args) {
            say sprintf '%15s : %s' =>
                $name,
                $arg->to_string;
        }
    }
}

class Eval::Expr :isa(Kontinue) {
    field $expr :param :reader;

    method kontinue {
        $self->DEBUG(expr => $expr);

        given (blessed $expr) {
            when ('Cons') {
                # given (blessed $expr->head)
                #   when Sym      -> resolve it and jump to Apply-Expr
                #   when Callable -> create Apply-Expr and call ->kontinue(Calleble)
                # ...
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
                my $value = $self->env->lookup($expr);
                return Error->new( env  => $self->env, error => "Unable to find ${expr} in Env" )
                    if not defined $value;
                return $self->kont->kontinue( $value );
            }
            default {
                return $self->kont->kontinue( $expr );
            }
        }
    }
}

class Apply::Expr :isa(Kontinue) {
    field $args :param :reader;

    method kontinue ($call) {
        $self->DEBUG(args => $args, '+call' => $call);
        # NOTE: we need to decide if applicative or operative here
        if ($call->is_operative) {
            return Apply::Call->new(
                env  => $self->env,
                call => $call,
                kont => $self->kont,
            )->kontinue(
                $args->uncons
            );
        } elsif ($args->is_nil) {
            # nullary ops
            return Apply::Call->new(
                env  => $self->env,
                call => $call,
                kont => $self->kont,
            );
        } elsif ($args->tail->is_nil) {
            # unary ops
            return Eval::Expr->new(
                env  => $self->env,
                expr => $args->head,
                kont => Apply::Call->new(
                    env  => $self->env,
                    call => $call,
                    kont => $self->kont,
                )
            )
        } else {
            # binary & list ops
            return Eval::Expr->new(
                env  => $self->env,
                expr => $args->head,
                kont => Eval::Rest->new(
                    env  => $self->env,
                    rest => $args->tail,
                    kont => Apply::Call->new(
                        env  => $self->env,
                        call => $call,
                        kont => $self->kont,
                    )
                )
            )
        }
    }
}

class Eval::Rest :isa(Kontinue) {
    field $rest :param :reader;
    field $done :param :reader = Nil->new;

    # 4. accumulate evaluates $args until nil and return to Apply-Call
    method kontinue ($evaled) {
        $self->DEBUG(rest => $rest, done => $done, '+evaled' => $evaled);
        if ($rest->is_nil) {
            return $self->kont->kontinue(
                Cons->new( head => $evaled, tail => $done )
            );
        } else {
            # given (blessed $rest->head)
            #     when Literal ... skip Eval-Expr
            # ... do this in a loop?
            return Eval::Expr->new(
                env  => $self->env,
                expr => $rest->head,
                kont => Eval::Rest->new(
                    env  => $self->env,
                    rest => $rest->tail,
                    done => Cons->new( head => $evaled, tail => $done ),
                    kont => $self->kont,
                )
            )
        }
    }
}

class Apply::Call :isa(Kontinue) {
    field $call :param :reader;

    method kontinue ($args) {
        $self->DEBUG(call => $call, '+args' => $args);

        given (blessed $call) {
            when ('Native') {
                my @args = reverse $args->uncons;
                if ($call->is_operative) {
                    unshift @args => $self->env;
                }
                return $self->kont->kontinue( $call->proc->( @args ) );
            }
            when ('Lambda') {
                my @args = reverse $args->uncons;

                my %local;
                my $params = $call->params;
                until ($params->is_nil) {
                    $local{ $params->head->ident } = pop @args;
                    $params = $params->tail;
                }

                my $local = Env->new( parent => $self->env, bindings => \%local );

                return Eval::Expr->new(
                    env  => $local,
                    expr => $call->body,
                    kont => $self->kont,
                );
            }
            default {
                # 5a. create new %ENV and bind $args to call parameters
                # 5b. create Scope-wrapped Eval-Expr with $call->body and new %ENV
                die "TODO"
            }
        }
    }
}

class Return :isa(Kontinue) {
    field $value :param :reader;

    method kontinue {
        $self->DEBUG('value' => $value);
        $self->kont->kontinue( $value );
    }
}

class Error :isa(Kontinue) {
    field $error :param :reader;

    method kontinue {
        $self->DEBUG('error' => $error);
        return undef;
    }
}

class Halt :isa(Kontinue) {
    field $result;

    method kontinue ($r) {
        $self->DEBUG('+result' => $r);
        $result = $r;
        return undef;
    }
}

## -----------------------------------------------------------------------------

my $env = Env->new(
    bindings => +{
        '+' => Native->new( name => '+', proc => sub ($n, $m) { num($n->raw + $m->raw) }),
        '-' => Native->new( name => '-', proc => sub ($n, $m) { num($n->raw - $m->raw) }),
        '*' => Native->new( name => '*', proc => sub ($n, $m) { num($n->raw * $m->raw) }),
        '/' => Native->new( name => '/', proc => sub ($n, $m) { num($n->raw / $m->raw) }),
        '%' => Native->new( name => '%', proc => sub ($n, $m) { num($n->raw % $m->raw) }),

        'ten' => Native->new( name => 'ten', proc => sub () { num(10) }),

        'lambda' => Native->new(
            name => 'lambda',
            proc => sub ($e, $p, $b) { Lambda->new( params => $p, body => $b, env => $e ) },
            is_operative => true,
        ),
    }
);


my $adder = cons(
    sym('lambda'),
    cons( sym('x'), sym('y') ),
    cons( sym('+'), sym('x'), sym('y') ),
);

my $expr = cons( $adder, num(10), num(20) );

say $expr;

my $epoch = 0;
my $halt = Halt->new( env => $env );
my $next = Eval::Expr->new( env => $env, expr => $expr, kont => $halt );
while (defined($next = $next->kontinue)) {
    $epoch++;
    #say ">>>>>>>[${epoch}]> ", $next;
}
say '-' x 120;
say "  TICKS: ", $Kontinue::TICKS;
say " EPOCHS: ", $epoch;
say '-' x 120;

























__END__


class Eval::Head :isa(Kontinue) {
    field $head :param :reader;
    field $rest :param :reader;

    # 2a. creates Apply-Expr with unevaled $rest
    # 2b. evaluates $head and returns it to Apply-Expr
    method kontinue {
        say '-' x 120;
        say sprintf '=> %-12s : %-12s : %s' => __CLASS__, (caller)[0], $self->kont;
        $Kontinue::tick++;
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
