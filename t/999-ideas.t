
use v5.42;
use utf8;
use open ':std', ':encoding(UTF-8)';
use experimental qw[ class switch ];

## -----------------------------------------------------------------------------

use constant DEBUG => $ENV{DEBUG} // 0;
use constant TRACE => $ENV{TRACE} // 0;

## -----------------------------------------------------------------------------

use constant OPTIMIZE_CALLS  => true;
use constant PRECOMPILE_DEFS => true;

## -----------------------------------------------------------------------------

our %ALLOCATIONS = (
    TERMS => +{},
    KONTS => +{},
    MISC  => +{},
);

our %STATS = (
    LOOKUPS     => 0,
    DEFINITIONS => +{
        COMPILETIME => +{},
        RUNTIME     => +{}
    }
);

## -----------------------------------------------------------------------------

class Parser {
    field @stack = (+[]);

    method tokenizer ($source) {
        $source =~ s/\;.*\n//g if $source =~ /\;/;
        grep !/^\s*$/, split /(\'\(|\(|\)|"(?:[^"\\]|\\.)*"|\s)/ => $source;
    }

    method parse ($source) {
        @stack = (+[]);
        my @tokens = $self->tokenizer($source);
        while (@tokens) {
            my $token = shift @tokens;
            if ($token =~ /^\'[^\(]/) {
                $token =~ s/^\'//;
                push @stack => +[ Sym->new(ident => 'quote' ) ];
                unshift @tokens => ')';
            }
            given ($token) {
                when (/^\"/)   { push $stack[-1]->@*, Str->new( raw => substr($token, 1, -1) ); }
                when (/^\d+$/) { push $stack[-1]->@*, Num->new( raw => $token+0 ); }
                when ('nil')   { push $stack[-1]->@*, Nil->new; }
                when ('true')  { push $stack[-1]->@*, Bool->TRUE; }
                when ('false') { push $stack[-1]->@*, Bool->FALSE; }
                when ('\'(')   { push @stack => +[ Sym->new(ident => 'quote' ) ]; }
                when ('(')     { push @stack => +[]; }
                when (')')     {
                    my $list = pop @stack;
                    push $stack[-1]->@*, (scalar $list->@* > 0)
                        ? Cons->of( $list->@* )
                        : Nil->new;
                }
                default {
                    push $stack[-1]->@*, Sym->new( ident => $token );
                }
            }
        }
        return $stack[-1];
    }
}

## -----------------------------------------------------------------------------

class Term {
    use overload '""' => 'to_string', fallback => false;
    method to_string { ... }
    method is_nil { false }

    method stringify { $self->to_string }

    ADJUST { $::ALLOCATIONS{TERMS}->{ blessed $self }++ }
}

class Sym :isa(Term) {
    field $ident :param :reader;
    method to_string { $ident }
}

class List :isa(Term) {}

class Nil :isa(List) {
    method to_string { '()' }
    method is_nil { true }
    method uncons { () }
}

class Cons :isa(List) {
    field $head :param :reader;
    field $tail :param :reader;

    sub of ($, @args) {
        my $list = Nil->new;
        $list = Cons->new( head => (pop @args), tail => $list )
            while @args;
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

    method to_string { sprintf '(%s)' => join ' ' => map {
        blessed $_ ? $_->to_string : "WTF!($_)"
    } $self->uncons }
}

class Literal :isa(Term) {}

class Str :isa(Literal) {
    field $raw :param :reader;
    method to_string { sprintf '"%s"' => ($raw =~ s/\n/\\n/r) }
    method stringify { $raw }
}

class Num :isa(Literal) {
    field $raw :param :reader;
    method to_string { "${raw}" }
}

class Bool :isa(Literal) {
    field $raw :param :reader;
    sub TRUE  { Bool->new( raw => true ) }
    sub FALSE { Bool->new( raw => false ) }
    method to_string { $raw ? 'true' : 'false' }
}

class Callable :isa(Literal) {
    method is_operative   { ... }
    method is_applicative { ... }
}

class Lambda :isa(Callable) {
    field $params :param :reader;
    field $body   :param :reader;
    field $env    :param :reader;
    field $name   :param :reader = undef;

    method has_name { defined $name }

    method is_operative   { false }
    method is_applicative { true  }

    method to_string { sprintf '(<lambda> %s %s)' => $params->to_string, $body->to_string }
}

class Native :isa(Callable) {
    field $name :param :reader;
    field $proc :param :reader;

    method has_name { defined $name }

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

    method derive (%bindings) {
        return Env->new( parent => $self, bindings => \%bindings )
    }

    method DUMP {
        return () unless defined $parent; # do not DUMP the root
        return $parent->DUMP, %$bindings;
    }

    ADJUST { $::ALLOCATIONS{MISC}->{ blessed $self }++ }
}

## -----------------------------------------------------------------------------

class Kontinue {
    use overload '""' => 'to_string', fallback => false;

    field $kont :param :reader = undef;

    method kontinue ($ctx) { ... }

    method to_string {
        return sprintf '%s!!', __CLASS__ if not defined $kont;
        return sprintf '%s > %s', __CLASS__, $kont->to_string;
    }

    method DEBUG (@args) {
        use Term::ReadKey ();
        state $WIDTH = (Term::ReadKey::GetTerminalSize)[0];

        say '-' x $WIDTH;
        say sprintf '=> %-12s : %s' => __CLASS__, substr($self->kont // '!!', 0, ($WIDTH - 20));
        say '-' x $WIDTH;
        foreach my ($name, $arg) (@args) {
            say sprintf '%15s : %s' =>
                $name,
                (blessed $arg ? $arg->to_string : $arg);
        }
    }

    ADJUST { $::ALLOCATIONS{KONTS}->{ blessed $self }++ }
}

## -----------------------------------------------------------------------------

class Eval::Expr :isa(Kontinue) {
    field $expr :param :reader;

    method kontinue ($ctx) {
        $self->DEBUG(expr => $expr) if ::DEBUG;

        given (blessed $expr) {
            when ('Cons') {
                my $next = Apply::Expr->new( args => $expr->tail, kont => $self->kont );

                if (::OPTIMIZE_CALLS) {
                    my $head;
                    if ($expr->head isa Callable) {
                        $head = $next->kontinue( $ctx, $expr->head );
                    }
                    elsif ($expr->head isa Sym) {
                        my $call = $ctx->lookup( $expr->head );
                        return $ctx->throw_error("Unable to find ".$expr->head." in Env", $self)
                            if not defined $call;
                        $head = $next->kontinue( $ctx, $call );
                    }

                    if (defined $head) {
                        return $head->kontinue( $ctx ) if $head isa Eval::Args;
                        return $head;
                    }
                }

                return Eval::Expr->new( expr => $expr->head, kont => $next );
            }
            when ('Sym') {
                my $value = $ctx->lookup($expr);
                return $ctx->throw_error("Unable to find ${expr} in Env", $self)
                    if not defined $value;
                return $ctx->return_value($value, $self->kont);
            }
            default {
                return $ctx->return_value($expr, $self->kont);
            }
        }
    }

    method to_string {
        return sprintf '%s[%s] > %s', __CLASS__, $expr->to_string, $self->kont->to_string;
    }
}

class Apply::Expr :isa(Kontinue) {
    field $args :param :reader;

    method kontinue ($ctx, $call) {
        $self->DEBUG(args => $args, '+call' => $call) if ::DEBUG;

        my $next = Apply::Call->new( call => $call, kont => $self->kont );

        return $ctx->return_value( $args, $next ) if $call->is_operative;

        if (::OPTIMIZE_CALLS) {
            if ($args->is_nil) {
                return $next;
            } elsif ($args->tail->is_nil) {
                return $ctx->return_value( Cons->of( $args->head ), $next )
                    if $args->head isa Literal;
                return Eval::Expr->new( expr => $args->head, kont => $next );
            } else {
                return Eval::Args->new( rest => $args, kont => $next )
            }
        }

        return Eval::Args->new( rest => $args, kont => $next )
    }

    method to_string {
        return sprintf '%s[%s] > %s', __CLASS__, $args->to_string, $self->kont->to_string;
    }
}

class Eval::Args :isa(Kontinue) {
    field $rest :param :reader;
    field $done :param :reader = Nil->new;

    method kontinue ($ctx, $value=undef) {
        $self->DEBUG(rest => $rest, done => $done, '+value' => $value // '?') if ::DEBUG;

        $done = Cons->new( head => $value, tail => $done )
            if defined $value;

        if (::OPTIMIZE_CALLS)  {
            until ($rest->is_nil) {
                last unless $rest->head isa Literal;
                $done = Cons->new( head => $rest->head, tail => $done );
                $rest = $rest->tail;
            }
        }

        # if no more left, return it
        return $ctx->return_value( $done->reverse, $self->kont )
            if $rest->is_nil;

        return Eval::Expr->new(
            expr => $rest->head,
            kont => Eval::Args->new(
                rest => $rest->tail,
                done => $done,
                kont => $self->kont,
            )
        );
    }

    method to_string {
        return sprintf '%s[%s][%s] > %s', __CLASS__, $rest->to_string, $done->to_string, $self->kont->to_string;
    }
}

class Apply::Call :isa(Kontinue) {
    field $call :param :reader;

    method bind_params ($ctx, $call, $args) {
        my %local;

        $local{ $call->name->ident } = $call
            if $call->has_name;

        my $params = $call->params;
        if ($args isa List) {
            until ($params->is_nil) {
                return $ctx->throw_error("Arity Mismatch - missing:${params}", $self)
                    if $args->is_nil;
                $local{ $params->head->ident } = $args->head;
                $params = $params->tail;
                $args   = $args->tail;
            }
            return $ctx->throw_error("Arity Mismatch - additional:${args}", $self)
                unless $args->is_nil;
        } else {
            return $ctx->throw_error("Arity Mismatch - additional:${args}", $self) if $params->is_nil;
            return $ctx->throw_error("Arity Mismatch - missing:${params}",  $self) unless $params->tail->is_nil;
            $local{ $params->head->ident } = $args;
        }

        return $call->env->derive( %local );
    }

    method kontinue ($ctx, $args) {
        $self->DEBUG(call => $call, '+args' => $args) if ::DEBUG;

        given (blessed $call) {
            when ('Native') {
                my @args = $args isa List ? $args->uncons : $args;
                if ($call->is_operative) {
                    return $call->proc->( $ctx, @args );
                } else {
                    return $ctx->return_value( $call->proc->( @args ), $self->kont );
                }
            }
            when ('Lambda') {
                return $ctx->wrap_in_scope(
                    $self->bind_params( $ctx, $call, $args ),
                    $call->body,
                    $self->kont
                )
            }
            default {
                die "Cannot call => ${call}";
            }
        }
    }

    method to_string {
        return sprintf '%s[%s] > %s', __CLASS__, $call->name, $self->kont->to_string;
    }
}

## ...

class Scope::Enter :isa(Kontinue) {
    field $env :param :reader;
    method kontinue ($ctx) {
        $self->DEBUG if ::DEBUG;
        $ctx->strand->enter_scope( $env );
        return $self->kont;
    }

    method to_string {
        return sprintf '%s[%s] > %s', __CLASS__, ($env =~ /(0x.*)\)$/), $self->kont->to_string;
    }
}

class Scope::Leave :isa(Kontinue) {
    method kontinue ($ctx, $result) {
        $self->DEBUG('+result' => $result) if ::DEBUG;
        $ctx->strand->leave_scope;
        return $ctx->return_value( $result, $self->kont );
    }
}

class Bind :isa(Kontinue) {
    field $name :param :reader;
    method kontinue ($ctx, $value) {
        $self->DEBUG('name' => $name, '+value' => $value) if ::DEBUG;
        $ctx->define( $name, $value );
        return $ctx->return_value( Nil->new, $self->kont );
    }

    method to_string {
        return sprintf '%s[%s] > %s', __CLASS__, $name->to_string, $self->kont->to_string;
    }
}

class Cond :isa(Kontinue) {
    field $if_true  :param :reader;
    field $if_false :param :reader;

    method kontinue ($ctx, $condition) {
        return Eval::Expr->new(
            expr => ($condition->raw ? $if_true : $if_false),
            kont => $self->kont
        );
    }
}

class Drop :isa(Kontinue) {
    method kontinue ($ctx, $dropped) {
        $self->DEBUG('-dropped' => $dropped) if ::DEBUG;
        return $self->kont;
    }
}

## ...

class Return :isa(Kontinue) {
    field $value :param :reader;

    method kontinue ($ctx) {
        $self->DEBUG('value' => $value) if ::DEBUG;
        return undef;
    }

    method to_string {
        return sprintf '%s[%s] > %s', __CLASS__, $value->to_string, $self->kont->to_string;
    }
}

class Yield :isa(Kontinue) {
    method kontinue ($ctx) {
        $self->DEBUG if ::DEBUG;
        return undef;
    }
}

class Error :isa(Kontinue) {
    field $error :param :reader;

    method kontinue ($ctx) {
        $self->DEBUG('error' => $error) if ::DEBUG;
        return undef;
    }
}

class Halt :isa(Kontinue) {
    field $result :reader;

    method kontinue ($ctx, $r) {
        $self->DEBUG('+result' => $r) if ::DEBUG;
        $result = $r;
        return undef;
    }

    method to_string {
        return sprintf '%s!! %s', __CLASS__, defined $result ? $result->to_string : '??';
    }
}

class Chan::Read :isa(Kontinue) {
    method kontinue ($ctx, $channel) {
        $self->DEBUG('@channel', $channel) if ::DEBUG;
        if ($channel->can_read) {
            my $value = $channel->read;
            return $ctx->return_value( $value, $self->kont );
        } else {
            return Yield->new( kont => $ctx->return_value( $channel, $self ) );
        }
    }
}

class Chan::Write :isa(Kontinue) {
    method kontinue ($ctx, $args) {
        my ($channel, $value) = $args->uncons;
        $self->DEBUG('@channel', $channel, '+value', $value) if ::DEBUG;
        $channel->write( $value );
        return $ctx->return_value( Nil->new, $self->kont );
    }
}

## -----------------------------------------------------------------------------

class Compiler {
    method link ($env, $expr) {
        given (blessed $expr) {
            when ('Cons') {
                return Cons->of( map { $self->link( $env, $_ ) } $expr->uncons );
            }
            when ('Sym') {
                return $env->lookup($expr) // $expr;
            }
            default {
                return $expr;
            }
        }
    }

    method compile ($env, $exprs) {
        my $kont  = Scope::Leave->new( kont => Halt->new );
        my @exprs = map { $self->link( $env, $_ ) } @$exprs;

        if (::PRECOMPILE_DEFS) {
            @exprs = map {
                if ($_ isa Cons
                &&  $_->head isa Callable
                &&  $_->head->name eq 'defun') {
                    my ($name, $params, $body) = $_->tail->uncons;
                    $env = $env->derive(
                        $name->ident, Lambda->new(
                            name   => $name,
                            params => $params,
                            body   => $body,
                            env    => $env,
                        )
                    );
                    $STATS{DEFINITIONS}->{COMPILETIME}++;
                    ();
                } elsif ($_ isa Cons
                    &&  $_->head isa Callable
                    &&  $_->head->name eq 'let') {
                    my ($name, $value) = $_->tail->uncons;
                    if ($value isa Literal) {
                        $env = $env->derive( $name->ident, $value );
                        $STATS{DEFINITIONS}->{COMPILETIME}++;
                        ();
                    } else {
                        $_;
                    }
                } else {
                    $_;
                }
            } @exprs;
        }

        foreach my $expr (reverse @exprs) {
            $kont = Eval::Expr->new(
                expr => $expr,
                kont => ($kont isa Scope::Leave)
                        ? $kont
                        : Drop->new( kont => $kont ));
        }
        return Scope::Enter->new( env => $env, kont => $kont );
    }

    ADJUST { $::ALLOCATIONS{MISC}->{ blessed $self }++; }
}

## -----------------------------------------------------------------------------

class Strand::Ref {
    field $strand :param :reader; # NOTE: weaken this

    method current_env     { $strand->current_env }
    method lookup ($s)     { $strand->lookup( $s ) }
    method define ($n, $v) { $strand->define( $n, $v ) }

    method wrap_in_scope ($env, $body, $kont) {
        Scope::Enter->new(
            env  => $env,
            kont => Eval::Expr->new(
                expr => $body,
                kont => Scope::Leave->new(
                    kont => $kont
                )
            )
        )
    }

    method do_block ($exprs, $kont=undef) {
        my $next = Scope::Leave->new( kont => $kont // $strand->next_kont );
        foreach my $expr (reverse @$exprs) {
            $next = Eval::Expr->new(
                expr => $expr,
                kont => ($next isa Scope::Leave)
                        ? $next
                        : Drop->new( kont => $next ));
        }
        return Scope::Enter->new( env => $self->current_env, kont => $next );
    }

    method bind ($name, $expr, $kont=undef) {
        Eval::Expr->new(
            expr => $expr,
            kont => Bind->new(
                name => $name,
                kont => $kont // $strand->next_kont
            )
        )
    }

    method throw_error ($error, $kont=undef) {
        Error->new( error => $error, kont => $kont // $strand->next_kont )
    }

    method return_value ($value, $kont=undef) {
        Return->new( value => $value, kont => $kont // $strand->next_kont )
    }

    method conditional ($condition, $if_true, $if_false, $kont=undef) {
        Eval::Expr->new(
            expr => $condition,
            kont => Cond->new(
                if_true  => $if_true,
                if_false => $if_false,
                kont     => $kont // $strand->next_kont,
            )
        )
    }

    method yield ($expr, $kont=undef) {
        Yield->new(
            kont => Eval::Expr->new(
                expr => $expr,
                kont => $kont // $strand->next_kont
            )
        )
    }

    method read_from_channel ($channel, $kont=undef) {
        Eval::Expr->new(
            expr => $channel,
            kont => Chan::Read->new(
                kont => $kont // $strand->next_kont,
            )
        )
    }

    method write_to_channel ($channel, $expr, $kont=undef) {
        Eval::Args->new(
            rest => Cons->of( $channel, $expr ),
            kont => Chan::Write->new(
                kont => $kont // $strand->next_kont
            )
        )
    }

    ADJUST { $::ALLOCATIONS{MISC}->{ blessed $self }++ }
}

## -----------------------------------------------------------------------------

class Strand {
    field $host  :param :reader;
    field $enter :param :reader;

    field $ref    :reader;
    field $steps  :reader;
    field @trace  :reader;
    field @envs   :reader;

    ADJUST {
        $ref    = Strand::Ref->new( strand => $self );
        $steps  = 0;
        $::ALLOCATIONS{MISC}->{ blessed $self }++;
    }

    ## -------------------------------------------------------------------------

    method enter_scope ($e) { push @envs => [ $e ] }
    method leave_scope      { pop @envs }
    method current_scope    { $envs[-1] }
    method current_env      { $self->current_scope->[-1] }

    method lookup ($sym) {
        $STATS{LOOKUPS}++;
        $self->current_env->lookup( $sym )
    }

    method define ($name, $value) {
        $STATS{DEFINITIONS}->{RUNTIME}++;
        push $self->current_scope->@* =>
            $self->current_env->derive( $name->ident, $value );
    }

    ## -------------------------------------------------------------------------

    method prev_kont { $trace[-1] }
    method next_kont { $trace[-1]->kont }

    ## -------------------------------------------------------------------------

    method run { $self->execute( $enter ) }

    method execute ($kont) {
        while (defined $kont) {
            push @trace => $kont;
            $kont = $self->step($kont);
        }
        return @trace;
    }

    method resume {
        return $self->execute( $enter ) unless @trace;
        return $self->execute( $self->next_kont ) if $self->prev_kont isa Yield;
        return $self->execute( $self->ref->throw_error(
            "You can only resume from enter, or from a Yield, not ".$self->prev_kont,
        ));
    }

    method step ($kont) {
        $steps++;
        given (blessed $kont) {
            #say "STEP: ",$steps;
            #say "ENV:";
            #if ($self->current_scope) {
            #    foreach my ($k, $v) ($self->current_env->DUMP) {
            #        say sprintf '  > %-10s : %s ...', $k, substr(blessed $v ? $v->to_string : "WTF($v)", 0, 60);
            #    }
            #}
            when ('Return') {
                push @trace => $kont->kont;
                return $kont->kont->kontinue( $self->ref, $kont->value );
            }
            default {
                return $kont->kontinue( $self->ref );
            }
        }
    }
}

## -----------------------------------------------------------------------------

class Channel :isa(Term) {
    field $name :param :reader = undef;

    field @w_buffer :reader;
    field @r_buffer  :reader;

    our $ID_SEQ = 0;
    ADJUST {
        $name //= sprintf '%02d' => ++$ID_SEQ;

        $::ALLOCATIONS{MISC}->{ blessed $self }++
    }

    method can_read    { !! scalar @r_buffer }
    method has_pending { !! scalar @w_buffer }

    method read { shift @r_buffer }

    method write (@terms) { push @w_buffer => @terms; return; }

    method flush {
        push @r_buffer => @w_buffer;
        @w_buffer = ();
        return $self->can_read;
    }

    method to_string {
        sprintf 'ch<%s>:r[%d]:w[%d]' => $name, (scalar @r_buffer), (scalar @w_buffer);
    }

    method DUMP {
        sprintf '%s {%s}<-{%s}' =>
            $self->to_string,
            (join ', ' => @r_buffer),
            (join ', ' => @w_buffer);
    }
}

## -----------------------------------------------------------------------------

class Channel::TTY :isa(Channel) {
    method can_read { true }
    method read { return Str->new( raw => my $input = <> ) }
    method write ($t) { print $t->stringify }
    method flush { $self->can_read }
    method to_string { sprintf 'ch(%s)[TTY]' => $self->name // '' }
}

## -----------------------------------------------------------------------------

class PID :isa(Term) {
    field $channel :param :reader;
    field $strand  :param :reader;
}

## -----------------------------------------------------------------------------

class Runtime {
    field $root_env :reader;
    field $compiler :reader;
    field $parser   :reader;
    field $stdin    :reader;
    field $stdout   :reader;

    ADJUST {
        $root_env = $self->initialize_root_env;
        $parser   = Parser->new;
        $compiler = Compiler->new;
        $stdin    = Channel::TTY->new( name => 'stdin' );
        $stdout   = Channel::TTY->new( name => 'stdout');

        $::ALLOCATIONS{MISC}->{ blessed $self }++;
    }

    ## -------------------------------------------------------------------------

    method parse ($src) { $parser->parse($src) }

    method compile ($env, $exprs) { $compiler->compile( $env, $exprs ) }

    ## -------------------------------------------------------------------------

    method initialize_strand ($kont) { Strand->new( host => $self, enter => $kont ) }

    method initialize_channel { Channel->new }

    ## -------------------------------------------------------------------------

    method initialize_root_env {
        return Env->new(
            bindings => +{
                '+' => Native->new( name => '+', proc => sub ($n, $m) { Num->new( raw => $n->raw + $m->raw ) }),
                '-' => Native->new( name => '-', proc => sub ($n, $m) { Num->new( raw => $n->raw - $m->raw ) }),
                '*' => Native->new( name => '*', proc => sub ($n, $m) { Num->new( raw => $n->raw * $m->raw ) }),
                '/' => Native->new( name => '/', proc => sub ($n, $m) { Num->new( raw => $n->raw / $m->raw ) }),
                '%' => Native->new( name => '%', proc => sub ($n, $m) { Num->new( raw => $n->raw % $m->raw ) }),

                '==' => Native->new( name => '==', proc => sub ($n, $m) { $n->raw == $m->raw ? Bool->TRUE : Bool->FALSE }),
                '!=' => Native->new( name => '!=', proc => sub ($n, $m) { $n->raw != $m->raw ? Bool->TRUE : Bool->FALSE }),
                '<=' => Native->new( name => '<=', proc => sub ($n, $m) { $n->raw <= $m->raw ? Bool->TRUE : Bool->FALSE }),
                '>=' => Native->new( name => '>=', proc => sub ($n, $m) { $n->raw >= $m->raw ? Bool->TRUE : Bool->FALSE }),
                '>'  => Native->new( name => '>',  proc => sub ($n, $m) { $n->raw >  $m->raw ? Bool->TRUE : Bool->FALSE }),
                '<'  => Native->new( name => '<',  proc => sub ($n, $m) { $n->raw <  $m->raw ? Bool->TRUE : Bool->FALSE }),

                '~' => Native->new( name => '~', proc => sub ($n, $m) { Str->new( raw => $n->stringify.$m->stringify ) }),

                'lambda' => Native->new(
                    name => 'lambda',
                    proc => sub ($ctx, $p, $b) {
                        $ctx->return_value( Lambda->new( params => $p, body => $b, env => $ctx->current_env ) )
                    },
                    is_operative => true,
                ),

                'if' => Native->new(
                    name => 'if',
                    proc => sub ($ctx, $condition, $if_true, $if_false) {
                        $ctx->conditional( $condition, $if_true, $if_false )
                    },
                    is_operative => true,
                ),

                'do' => Native->new(
                    name => 'do',
                    proc => sub ($ctx, @exprs) { $ctx->do_block( \@exprs ) },
                    is_operative => true,
                ),

                'yield' => Native->new(
                    name => 'yield',
                    proc => sub ($ctx, $expr) { $ctx->yield( $expr ) },
                    is_operative => true,
                ),

                'let' => Native->new(
                    name => 'let',
                    proc => sub ($ctx, $name, $value) { $ctx->bind( $name, $value ) },
                    is_operative => true,
                ),

                'defun' => Native->new(
                    name => 'defun',
                    proc => sub ($ctx, $name, $params, $body) {
                        return $ctx->bind(
                            $name,
                            Lambda->new(
                                name   => $name,
                                params => $params,
                                body   => $body,
                                env    => $ctx->current_env,
                            )
                        )
                    },
                    is_operative => true,
                ),

                ## -------------------------------------------------------------
                ## Channels
                ## -------------------------------------------------------------

                'recv' => Native->new(
                    name => 'recv',
                    proc => sub ($ctx, $ch) { $ctx->read_from_channel( $ch ) },
                    is_operative => true,
                ),

                'send' => Native->new(
                    name => 'send',
                    proc => sub ($ctx, $ch, $expr) { $ctx->write_to_channel( $ch, $expr ) },
                    is_operative => true,
                ),

                ## -------------------------------------------------------------
                ## TTY
                ## -------------------------------------------------------------

                '*stdin' => Native->new(
                    name => '*stdin',
                    proc => sub ($ctx) { $ctx->return_value( $ctx->strand->host->stdin ) },
                    is_operative => true,
                ),

                '*stdout' => Native->new(
                    name => '*stdout',
                    proc => sub ($ctx) { $ctx->return_value( $ctx->strand->host->stdout ) },
                    is_operative => true,
                ),

                '<>' => Native->new(
                    name => '<>',
                    proc => sub ($ctx) { $ctx->read_from_channel( $ctx->strand->host->stdin ) },
                    is_operative => true,
                ),
                'print' => Native->new(
                    name => 'print',
                    proc => sub ($ctx, $expr) {
                        $ctx->write_to_channel( $ctx->strand->host->stdout, $expr )
                    },
                    is_operative => true,
                ),
                'say' => Native->new(
                    name => 'say',
                    proc => sub ($ctx, $expr) {
                        $ctx->write_to_channel( $ctx->strand->host->stdout, Cons->of( Sym->new(ident => '~'), $expr, Str->new(raw => "\n") ) )
                    },
                    is_operative => true,
                ),

            }
        )
    }
}


my $host = Runtime->new;

my $actors = q[

(defun PING ($in $out) (do
    (say "> PING IS LOOKING FOR A MESSAGE ...")
    (let count (recv $in))
    (say (~ "> PING GOT MESSAGE FROM PONG! " count))
    (if (> count 1)
        (do
            (say (~ "> PING IS RESPONDING w/ " (- count 1)))
            (send $out (- count 1))
            (say "< PING IS YIELDING")
            (yield (PING $in $out)))
        (do
            (say "! PING IS DONE, SENDING 0 TO PONG!")
            (send $out 0)
            (say "> PING IS DONE!")))))

(defun PONG ($in $out) (do
    (say "> PONG IS LOOKING FOR A MESSAGE ...")
    (let count (recv $in))
    (say (~ "> PONG GOT MESSAGE FROM PING! " count))
    (if (> count 1)
        (do
            (say (~ "> PONG IS RESPONDING w/ " (- count 1)))
            (send $out (- count 1))
            (say "< PONG IS YIELDING")
            (yield (PONG $in $out)))
        (do
            (say "! PONG IS DONE, SENDING 0 TO PING!")
            (send $out 0)
            (say "> PONG IS DONE!")))))

(PING $ping $pong)
(PONG $pong $ping)

];

my $exprs = $host->parse($actors);

my $ping_chan = $host->initialize_channel;
my $pong_chan = $host->initialize_channel;

my $env = $host->root_env->derive(
    '$ping' => $ping_chan,
    '$pong' => $pong_chan,
);

my ($Ping, $Pong, $ping, $pong, $trigger) = @$exprs;
my $Pinger = $host->compile( $env, [ $Ping, $ping ] );
my $Ponger = $host->compile( $env, [ $Pong, $pong ] );
my $pinger = $host->initialize_strand( $Pinger );
my $ponger = $host->initialize_strand( $Ponger );

my %names = ( $pinger => 'pinger', $ponger => 'ponger' );

$ping_chan->write(Num->new(raw => 10));

say "Starting channels ... ";
say '-' x 80;
say "  ->ping: ",$ping_chan->DUMP;
say "  ->pong: ",$pong_chan->DUMP;
say '=' x 80;

my @channels = ($ping_chan, $pong_chan);
my @queue    = ($pinger, $ponger);
while (true) {
    #say "Flushing channels ... ";
    foreach my $ch (@channels) {
        if ($ch->has_pending) {
            $ch->flush;
        }
    }
    #say '-' x 80;
    #say "  ->ping: ",$ping_chan->DUMP;
    #say "  ->pong: ",$pong_chan->DUMP;
    #say '=' x 80;
    my $strand = shift @queue;
    say "Running ... ",$names{$strand},' @ ',$strand->steps;
    #say '-' x 80;
    my @trace  = $strand->resume;
    #say '-' x 80;
    #say "PREV : ", blessed $trace[-2];
    #say "CURR : ", blessed $trace[-1];
    #say "NEXT : ", defined($trace[-1]->kont) ? blessed $trace[-1]->kont : '~';
    #say '-' x 80;
    #say "  ->ping: ",$ping_chan->DUMP;
    #say "  ->pong: ",$pong_chan->DUMP;
    #say '-' x 80;
    if ($trace[-1]->isa('Error')) {
        die $trace[-1]->error;
    }

    if ($trace[-1]->isa('Halt')) {
        #say "Halting ... ",$names{$strand},' @ ',$strand->steps;
        last unless @queue;
    } else {
        #say "Yielding ... ",$names{$strand},' @ ',$strand->steps;
        push @queue => $strand;
    }
    #say '=' x 80;
    #my $x = <>;
}


__END__

my $exprs = $host->parse(q[

(defun fact (n)
    (if (== n 0) 1
        (* n (fact (- n 1)))))

(defun fib (n)
    (if (< n 2) n
        (+ (fib (- n 2)) (fib (- n 1)))))

(say (~ "FACT/FIB=" (fact (fib 6))))

]);

say "PARSED:";
say '    - ', $_ foreach @$exprs;

my $compiled = $host->compile( $host->root_env, $exprs );

say "COMPILED:";
foreach my ($name, $f) ($compiled->env->DUMP) {
    say '    - ', $name, ' := ', $f;
}
say '    + (main)';
say '       ', $compiled;

my @trace = $host->initialize_strand( $compiled )->run;

say "STATS:";
say "    STEPS : ", scalar @trace;
say "  DEFINES : ", $STATS{DEFINES} // 0;
say "  LOOKUPS : ", $STATS{LOOKUPS} // 0;

if (TRACE) {
    say "TRACE:";
    say join "\n" => @trace;
} else {
    say "GOT:";
    say '    - ', $trace[-1];
}

say "ALLOCATIONS:";
say " +TERMS:";
foreach my $type (sort { $ALLOCATIONS{TERMS}->{$b} <=> $ALLOCATIONS{TERMS}->{$a} } keys $ALLOCATIONS{TERMS}->%*) {
    say sprintf '%16s : %d' => $type, $ALLOCATIONS{TERMS}->{$type};
}
say " +KONTS:";
foreach my $type (sort { $ALLOCATIONS{KONTS}->{$b} <=> $ALLOCATIONS{KONTS}->{$a} } keys $ALLOCATIONS{KONTS}->%*) {
    say sprintf '%16s : %d' => $type, $ALLOCATIONS{KONTS}->{$type};
}
say " +MISC:";
foreach my $type (sort { $ALLOCATIONS{MISC}->{$b} <=> $ALLOCATIONS{MISC}->{$a} } keys $ALLOCATIONS{MISC}->%*) {
    say sprintf '%16s : %d' => $type, $ALLOCATIONS{MISC}->{$type};
}


__DATA__
(let x 6)


(defun fact (n)
    (if (== n 0) 1
        (* n (fact (- n 1)))))

(defun fib (n)
    (if (< n 2) n
        (+ (fib (- n 2)) (fib (- n 1)))))

(fact (fib 6))


















