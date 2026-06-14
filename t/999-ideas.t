
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

class List :isa(Term) {}

class Nil :isa(List) {
    method to_string { '()' }
    method is_nil { true }
}

class Cons :isa(List) {
    field $head :param :reader;
    field $tail :param :reader;

    sub of ($, @args) {
        my $list = Nil->new;
        while (@args) {
            $list = Cons->new( head => (pop @args), tail => $list );
        }
        return $list;
    }

    method reverse { Cons->of( reverse $self->uncons ) }

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

class Literal :isa(Term) {}

class Str  :isa(Literal) {field $raw :param :reader; method to_string { $raw }}
class Num  :isa(Literal) {field $raw :param :reader; method to_string { "${raw}" }}
class Bool :isa(Literal) {field $raw :param :reader; method to_string { $raw ? 'true' : 'false' }}

class Callable :isa(Literal) {
    method is_operative   { ... }
    method is_applicative { ... }
}

class Lambda :isa(Callable) {
    field $params :param :reader;
    field $body   :param :reader;
    field $env    :param :reader;

    method is_operative   { false }
    method is_applicative { true  }

    method to_string { sprintf '(lambda %s %s)' => $params->to_string, $body->to_string }
}

class Native :isa(Callable) {
    field $name :param :reader;
    field $proc :param :reader;

    field $is_operative :param :reader = false;
    method is_applicative { !$is_operative }

    method to_string { sprintf '#<%s>' => $name }
}

## -----------------------------------------------------------------------------

class Env {
    field $parent   :param :reader = undef;
    field $bindings :param :reader = +{};

    method lookup ($sym) {
        return $bindings->{ $sym->ident }
            // (defined $parent ? $parent->lookup($sym) : undef);
    }
}

## -----------------------------------------------------------------------------

class Kontinue {
    use overload '""' => 'to_string';

    field $env  :param :reader;
    field $kont :param :reader = undef;

    method to_string {
        sprintf '%s > %s', __CLASS__, defined $kont ? $kont->to_string : '!!';
    }

    method throw_error ($error) {
        Error->new( env => $self->env, error => $error, kont => $self->kont )
    }

    method return_value ($value, $kont=undef) {
        Return->new( env => $self->env, value => $value, kont => $kont // $self->kont )
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
                (blessed $arg ? $arg->to_string : $arg);
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
                return $self->throw_error("Unable to find ${expr} in Env")
                    if not defined $value;
                return $self->return_value($value);
            }
            default {
                return $self->return_value($expr);
            }
        }
    }
}

class Apply::Expr :isa(Kontinue) {
    field $args :param :reader;

    method kontinue ($call) {
        $self->DEBUG(args => $args, '+call' => $call);
        if ($call->is_operative) {
            return $self->return_value( $args,
                Apply::Call->new(
                    env  => $self->env,
                    call => $call,
                    kont => $self->kont,
                )
            );
        } else {
            return Eval::Rest->new(
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
}

class Eval::Rest :isa(Kontinue) {
    field $rest :param :reader;
    field $done :param :reader = Nil->new;

    method kontinue ($evaled=undef) {
        $self->DEBUG(rest => $rest, done => $done, '+evaled' => $evaled // '?');

        $done = Cons->new( head => $evaled, tail => $done )
            if defined $evaled;

        until ($rest->is_nil) {
            my $next = $rest->head;
            if ($next isa Literal) {
                $done = Cons->new( head => $next, tail => $done );
                $rest = $rest->tail;
            } else {
                last;
            }
        }

        return $self->return_value( $done->reverse )
            if $rest->is_nil;

        return Eval::Expr->new(
            env  => $self->env,
            expr => $rest->head,
            kont => Eval::Rest->new(
                env  => $self->env,
                rest => $rest->tail,
                done => $done,
                kont => $self->kont,
            )
        );
    }
}

class Apply::Call :isa(Kontinue) {
    field $call :param :reader;

    method kontinue ($args) {
        $self->DEBUG(call => $call, '+args' => $args);

        given (blessed $call) {
            when ('Native') {
                my @args = $args->uncons;
                if ($call->is_operative) {
                    return $call->proc->( $self, @args );
                } else {
                    return $self->return_value( $call->proc->( @args ) );
                }
            }
            when ('Lambda') {
                my %local;
                my $params = $call->params;
                until ($params->is_nil) {
                    return $self->throw_error("Arity Mismatch - missing:${params}")
                        if $args->is_nil;
                    $local{ $params->head->ident } = $args->head;
                    $params = $params->tail;
                    $args   = $args->tail;
                }
                return $self->throw_error("Arity Mismatch - additional:${args}")
                    unless $args->is_nil;

                my $local = Env->new( parent => $self->env, bindings => \%local );

                return Eval::Expr->new(
                    env  => $local,
                    expr => $call->body,
                    kont => $self->kont,
                );
            }
            default {
                die "Cannot call => ${call}";
            }
        }
    }
}

class Return :isa(Kontinue) {
    field $value :param :reader;

    method kontinue {
        $self->DEBUG('value' => $value);
        return $value;
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

sub sym ($i) { Sym->new( ident => $i ) }
sub num ($n) { Num->new(   raw => $n ) }
sub str ($s) { Str->new(   raw => $s ) }

sub cons (@args) { Cons->of(@args) }

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
            proc => sub ($ctx, $p, $b) {
                $ctx->return_value(
                    Lambda->new( params => $p, body => $b, env => $ctx->env )
                )
            },
            is_operative => true,
        ),
    }
);


my $adder = cons(
    sym('lambda'),
    cons( sym('x'), sym('y') ),
    cons( sym('+'), sym('x'), sym('y') ),
);

my $expr = cons(
    $adder,
    num(10),
    cons( sym('*'), num(4), num(5) ),
);

say $expr;

my $epoch = 0;
my $halt = Halt->new( env => $env );
my $next = Eval::Expr->new( env => $env, expr => $expr, kont => $halt );
while (defined $next) {
    $epoch++;
    given (blessed $next) {
        when ('Return') {
            $next = $next->kont->kontinue( $next->value );
        }
        when ('Error') {
            $next = $next->kontinue; # good enough for now
        }
        when ('Halt') {
            $next = $next->kontinue; # good enough for now
        }
        default {
            $next = $next->kontinue;
        }
    }
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
