
use v5.42;
use utf8;
use open ':std', ':encoding(UTF-8)';
use experimental qw[ class switch ];

## -----------------------------------------------------------------------------

use constant DEBUG => $ENV{DEBUG} // 0;
use constant TRACE => $ENV{TRACE} // 0;

## -----------------------------------------------------------------------------

use constant OPTIMIZE_CALLS  => false;
use constant PRECOMPILE_DEFS => false;

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
## Terms
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

class Tag :isa(Term) {
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

    method to_string { sprintf '(%s)' => join ' ' => map $_->to_string, $self->uncons }
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

    ADJUST { $name = Sym->new(ident => $name) }

    field $is_operative :param :reader = false;
    method is_applicative { !$is_operative }

    method to_string { sprintf '#<%s>' => $name }
}

class PID :isa(Term) {
    field $id      :param :reader;
    field $channel :param :reader;
    field $strand  :param :reader;

    method to_string {
        sprintf 'PID<%04d>' => $id;
    }

    method DUMP {
        sprintf 'PID<%04d> %s' => $id, $channel->to_string;
    }
}

class Channel :isa(Term) {
    # FIXME: turn this into something else
    # not just a name, and maybe associate
    # it with PID id somehow???
    field $name :param :reader = undef;

    field @w_buffer :reader;
    field @r_buffer  :reader;

    our $ID_SEQ = 0;
    ADJUST {
        $name //= sprintf '%02d' => ++$ID_SEQ;
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

class Env :isa(Term) {
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

    method to_string {
        sprintf 'ENV<%s>' => join '; ' => sort { $a cmp $b } keys $bindings->%*;
    }
}

## -----------------------------------------------------------------------------
## Kontinues
## -----------------------------------------------------------------------------

class Kontinue {
    use overload '""' => 'to_string', fallback => false;

    field $kont :param :reader = undef;

    method kontinue ($ctx) { ... }

    method to_string {
        return sprintf '%s!!', __CLASS__ if not defined $kont;
        return sprintf '%s > %s', __CLASS__, $kont->to_string;
    }

    method DEBUG ($ctx, @args) {
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

class Eval::Expr :isa(Kontinue) {
    field $expr :param :reader;

    method kontinue ($ctx) {
        $self->DEBUG($ctx, expr => $expr) if ::DEBUG;

        given (blessed $expr) {
            when ('Cons') {
                my $next = Apply::Expr->new( args => $expr->tail, kont => $self->kont );

                if (::OPTIMIZE_CALLS) {
                    my $head;
                    if ($expr->head isa Callable) {
                        $head = $next->kontinue( $ctx, $expr->head );
                    }
                    elsif ($expr->head isa Sym) {
                        my $call = $ctx->strand->lookup( $expr->head );
                        return $ctx->strand->throw_error("Unable to find ".$expr->head->to_string." in Env", $self)
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
                my $value = $ctx->strand->lookup($expr);
                return $ctx->strand->throw_error("Unable to find ".$expr->to_string." in Env", $self)
                    if not defined $value;
                return $ctx->strand->return_value($value, $self->kont);
            }
            default {
                return $ctx->strand->return_value($expr, $self->kont);
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
        $self->DEBUG($ctx, args => $args, '+call' => $call) if ::DEBUG;

        my $next = Apply::Call->new( call => $call, kont => $self->kont );

        return $ctx->strand->return_value( $args, $next ) if $call->is_operative;

        if (::OPTIMIZE_CALLS) {
            if ($args->is_nil) {
                return $next;
            } elsif ($args->tail->is_nil) {
                return $ctx->strand->return_value( Cons->of( $args->head ), $next )
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
        $self->DEBUG($ctx, rest => $rest, done => $done, '+value' => $value // '?') if ::DEBUG;

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
        return $ctx->strand->return_value( $done->reverse, $self->kont )
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
                return $ctx->strand->throw_error("Arity Mismatch - missing:".$params->to_string, $self)
                    if $args->is_nil;
                $local{ $params->head->ident } = $args->head;
                $params = $params->tail;
                $args   = $args->tail;
            }
            return $ctx->strand->throw_error("Arity Mismatch - additional:".$args->to_string, $self)
                unless $args->is_nil;
        } else {
            return $ctx->strand->throw_error("Arity Mismatch - additional:".$args->to_string, $self) if $params->is_nil;
            return $ctx->strand->throw_error("Arity Mismatch - missing:".$params->to_string,  $self) unless $params->tail->is_nil;
            $local{ $params->head->ident } = $args;
        }

        return $call->env->derive( %local );
    }

    method kontinue ($ctx, $args=undef) {
        $args //= Nil->new;
        $self->DEBUG($ctx, call => $call, '+args' => $args) if ::DEBUG;

        given (blessed $call) {
            when ('Native') {
                my @args = $args isa List ? $args->uncons : $args;
                if ($call->is_operative) {
                    return $call->proc->( $ctx, @args );
                } else {
                    return $ctx->strand->return_value( $call->proc->( @args ), $self->kont );
                }
            }
            when ('Lambda') {
                return $ctx->strand->wrap_in_scope(
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
        $self->DEBUG($ctx) if ::DEBUG;
        $ctx->strand->enter_scope( $env );
        return $self->kont;
    }

    method to_string {
        return sprintf '%s[%s] > %s', __CLASS__, $env->to_string, $self->kont->to_string;
    }
}

class Scope::Leave :isa(Kontinue) {
    method kontinue ($ctx, $result=undef) {
        $result = Nil->new unless defined $result;
        $self->DEBUG($ctx, '+result' => $result) if ::DEBUG;
        $ctx->strand->leave_scope;
        return $ctx->strand->return_value( $result, $self->kont );
    }
}

class Bind :isa(Kontinue) {
    field $name :param :reader;
    method kontinue ($ctx, $value) {
        $self->DEBUG($ctx, 'name' => $name, '+value' => $value) if ::DEBUG;
        $ctx->strand->define( $name, $value );
        return $ctx->strand->return_value( Nil->new, $self->kont );
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
        $self->DEBUG($ctx, '-dropped' => $dropped) if ::DEBUG;
        return $self->kont;
    }
}

## ...

class Return :isa(Kontinue) {
    field $value :param :reader;

    method kontinue ($ctx) {
        $self->DEBUG($ctx, 'value' => $value) if ::DEBUG;
        return undef;
    }

    method to_string {
        return sprintf '%s[%s] > %s', __CLASS__, $value->to_string, $self->kont->to_string;
    }
}

class Yield :isa(Kontinue) {
    method kontinue ($ctx) {
        $self->DEBUG($ctx) if ::DEBUG;
        return undef;
    }
}

class Error :isa(Kontinue) {
    field $error :param :reader;

    method kontinue ($ctx) {
        $self->DEBUG($ctx, 'error' => $error) if ::DEBUG;
        return undef;
    }
}

class Halt :isa(Kontinue) {
    field $result :reader;

    method kontinue ($ctx, $r) {
        $self->DEBUG($ctx, '+result' => $r) if ::DEBUG;
        $result = $r;
        return undef;
    }

    method to_string {
        return sprintf '%s!! %s', __CLASS__, defined $result ? $result->to_string : '??';
    }
}

class Spawn :isa(Kontinue) {
    field $expr :param :reader;

    method kontinue ($ctx) {
        $self->DEBUG($ctx) if ::DEBUG;
        my $kont = $ctx->strand->host->compile( $ctx->strand->current_env, [ $expr ] );
        my $pid  = $ctx->strand->host->spawn( $kont );
        return $ctx->strand->return_value( $pid, $self->kont );
    }
}

class Chan::Read :isa(Kontinue) {
    method kontinue ($ctx, $channel=undef) {
        $channel = $ctx unless defined $channel;

        if ($channel isa PID) {
            $self->DEBUG($ctx, '@PID', $channel) if ::DEBUG;
            $channel = $channel->channel;
        } else {
            $self->DEBUG($ctx, '@channel', $channel) if ::DEBUG;
        }
        if ($channel->can_read) {
            my $value = $channel->read;
            return $ctx->strand->return_value( $value, $self->kont );
        } else {
            return Yield->new( kont => $ctx->strand->return_value( $channel, $self ) );
        }
    }
}

class Chan::Write :isa(Kontinue) {
    method kontinue ($ctx, $args) {
        my ($channel, $value);
        if ($args->tail->is_nil) {
            $channel = $ctx;
            $value   = $args->head;
        } else {
            ($channel, $value) = $args->uncons;
        }

        if ($channel isa PID) {
            $self->DEBUG($ctx, '@PID', $channel, '+value', $value) if ::DEBUG;
            $channel = $channel->channel;
        } else {
            $self->DEBUG($ctx, '@channel', $channel, '+value', $value) if ::DEBUG;
        }

        $channel->write( $value );
        return $ctx->strand->return_value( Nil->new, $self->kont );
    }
}

## -----------------------------------------------------------------------------
## Parser
## -----------------------------------------------------------------------------
## TODO:
## - fix number handling to parse decimals
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
                    push $stack[-1]->@*,
                        $token =~ /^\:/
                            ? Tag->new( ident => $token )
                            : Sym->new( ident => $token );
                }
            }
        }
        return $stack[-1];
    }
}

## -----------------------------------------------------------------------------
## Compiler
## -----------------------------------------------------------------------------
## NOTES:
## - link could break lexical shadowing of builtins
## - link is also done when spawn happens, which could get tricky
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
                &&  $_->head->name->ident eq 'defun') {
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
                    &&  $_->head->name->ident eq 'let') {
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

class Strand {
    field $host  :param :reader;
    field $enter :param :reader;
    field $pid   :param :reader;

    field $steps  :reader;
    field @trace  :reader;
    field @envs   :reader;

    ADJUST {
        $pid   = PID->new( id => $pid, strand => $self, channel => Channel->new );
        $steps = 0;
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

    method throw_error ($error, $kont=undef) {
        Error->new( error => $error, kont => $kont // $self->next_kont )
    }

    method return_value ($value, $kont=undef) {
        Return->new( value => $value, kont => $kont // $self->next_kont )
    }


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
        my $next = Scope::Leave->new( kont => $kont // $self->next_kont );
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
                kont => $kont // $self->next_kont
            )
        )
    }

    method conditional ($condition, $if_true, $if_false, $kont=undef) {
        Eval::Expr->new(
            expr => $condition,
            kont => Cond->new(
                if_true  => $if_true,
                if_false => $if_false,
                kont     => $kont // $self->next_kont,
            )
        )
    }

    method yield ($expr, $kont=undef) {
        Yield->new(
            kont => Eval::Expr->new(
                expr => $expr,
                kont => $kont // $self->next_kont
            )
        )
    }

    method read_from_channel (@args) {
        return Chan::Read->new( kont => $self->next_kont )
            if scalar @args == 0;

        return Chan::Read->new( kont => $args[0] )
            if $args[0] isa Kontinue;

        my ($channel, $kont) = @args;

        return Eval::Expr->new(
            expr => $channel,
            kont => Chan::Read->new(
                kont => $kont // $self->next_kont,
            )
        )
    }

    method write_to_channel (@args) {
        if (scalar @args == 1) {
            my ($expr) = @args;
            return Eval::Args->new(
                rest => Cons->of( $expr ),
                kont => Chan::Write->new( kont => $self->next_kont )
            )
        }
        elsif (scalar @args == 3) {
            my ($channel, $expr, $kont) = @args;
            return Eval::Args->new(
                rest => Cons->of( $channel, $expr ),
                kont => Chan::Write->new( kont => $kont )
            )
        }
        elsif (scalar @args == 2) {
            my ($expr, $kont);
            if ($args[-1] isa Kontinue) {
                $expr = Cons->of( $args[0] );
                $kont = $args[1];
            } else {
                $expr = Cons->of( @args );
            }
            return Eval::Args->new(
                rest => $expr,
                kont => Chan::Write->new( kont => $kont // $self->next_kont )
            )
        }
        else {
            die "WTF too many args dude!"
        }
    }

    method spawn_pid ($expr, $kont=undef) {
        Spawn->new( expr => $expr, kont => $kont // $self->next_kont )
    }

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
        return $self->execute( $self->throw_error(
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
                return $kont->kont->kontinue( $self->pid, $kont->value );
            }
            default {
                return $kont->kontinue( $self->pid );
            }
        }
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

class Runtime {
    field $root_env :reader;
    field $compiler :reader;
    field $parser   :reader;
    field $stdin    :reader;
    field $stdout   :reader;
    field @pids     :reader;

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

    our $ID_SEQ = 0;

    method spawn ($kont) {
        my $strand = Strand->new(
            pid   => $ID_SEQ++,
            host  => $self,
            enter => $kont,
        );
        push @pids => $strand->pid;
        return $strand->pid;
    }

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

                '~'  => Native->new( name => '~',  proc => sub (@args) { Str->new( raw => join '' => map $_->stringify, @args ) }),

                'eq' => Native->new( name => 'eq', proc => sub ($n, $m) { $n->raw eq $m->raw ? Bool->TRUE : Bool->FALSE }),
                'ne' => Native->new( name => 'ne', proc => sub ($n, $m) { $n->raw ne $m->raw ? Bool->TRUE : Bool->FALSE }),
                'le' => Native->new( name => 'le', proc => sub ($n, $m) { $n->raw le $m->raw ? Bool->TRUE : Bool->FALSE }),
                'ge' => Native->new( name => 'ge', proc => sub ($n, $m) { $n->raw ge $m->raw ? Bool->TRUE : Bool->FALSE }),
                'gt' => Native->new( name => 'gt', proc => sub ($n, $m) { $n->raw gt $m->raw ? Bool->TRUE : Bool->FALSE }),
                'lt' => Native->new( name => 'lt', proc => sub ($n, $m) { $n->raw lt $m->raw ? Bool->TRUE : Bool->FALSE }),

                'atom?'     => Native->new( name => 'atom?',     proc => sub ($n, $m) { $n isa Literal  ? Bool->TRUE : Bool->FALSE }),
                'list?'     => Native->new( name => 'bool?',     proc => sub ($n, $m) { $n isa List     ? Bool->TRUE : Bool->FALSE }),
                'callable?' => Native->new( name => 'callable?', proc => sub ($n, $m) { $n isa Callable ? Bool->TRUE : Bool->FALSE }),
                'nil?'      => Native->new( name => 'nil?',      proc => sub ($n, $m) { $n isa Nil      ? Bool->TRUE : Bool->FALSE }),
                'num?'      => Native->new( name => 'num?',      proc => sub ($n, $m) { $n isa Num      ? Bool->TRUE : Bool->FALSE }),
                'str?'      => Native->new( name => 'str?',      proc => sub ($n, $m) { $n isa Str      ? Bool->TRUE : Bool->FALSE }),
                'bool?'     => Native->new( name => 'bool?',     proc => sub ($n, $m) { $n isa Bool     ? Bool->TRUE : Bool->FALSE }),
                'tag?'      => Native->new( name => 'tag?',      proc => sub ($n, $m) { $n isa Tag      ? Bool->TRUE : Bool->FALSE }),
                'sym?'      => Native->new( name => 'sym?',      proc => sub ($n, $m) { $n isa Sym      ? Bool->TRUE : Bool->FALSE }),
                'native?'   => Native->new( name => 'native?',   proc => sub ($n, $m) { $n isa Native   ? Bool->TRUE : Bool->FALSE }),
                'lambda?'   => Native->new( name => 'lambda?',   proc => sub ($n, $m) { $n isa Lambda   ? Bool->TRUE : Bool->FALSE }),
                'channel?'  => Native->new( name => 'channel?',  proc => sub ($n, $m) { $n isa Channel  ? Bool->TRUE : Bool->FALSE }),
                'pid?'      => Native->new( name => 'pid?',      proc => sub ($n, $m) { $n isa PID      ? Bool->TRUE : Bool->FALSE }),

                'list'  => Native->new( name => 'list',  proc => sub (@args)  { Cons->of( @args ) }),
                'cons'  => Native->new( name => 'cons',  proc => sub ($h, $t) { Cons->new( head => $h, tail => $t ) }),
                'car'   => Native->new( name => 'car',   proc => sub ($list)  { $list->head }),
                'cdr'   => Native->new( name => 'cdr',   proc => sub ($list)  { $list->tail }),
                'caar'  => Native->new( name => 'caar',  proc => sub ($list)  { $list->head->head }),
                'cadr'  => Native->new( name => 'cadr',  proc => sub ($list)  { $list->head->tail }),
                'cdar'  => Native->new( name => 'cdar',  proc => sub ($list)  { $list->tail->head }),
                'cadar' => Native->new( name => 'cadar', proc => sub ($list)  { $list->head->tail->head }),
                'caddr' => Native->new( name => 'caddr', proc => sub ($list)  { $list->head->tail->tail }),
                'cddar' => Native->new( name => 'cddar', proc => sub ($list)  { $list->tail->tail->head }),

                'quote' => Native->new(
                    name => 'quote',
                    proc => sub ($ctx, @args) {
                        $ctx->strand->return_value(
                            scalar @args == 1 ? $args[0] : Cons->of( @args )
                        )
                    },
                    is_operative => true,
                ),

                'lambda' => Native->new(
                    name => 'lambda',
                    proc => sub ($ctx, $params, $body) {
                        $ctx->strand->return_value(
                            Lambda->new(
                                params => $params,
                                body   => $body,
                                env    => $ctx->strand->current_env
                            )
                        )
                    },
                    is_operative => true,
                ),

                'if' => Native->new(
                    name => 'if',
                    proc => sub ($ctx, $condition, $if_true, $if_false) {
                        $ctx->strand->conditional( $condition, $if_true, $if_false )
                    },
                    is_operative => true,
                ),

                'do' => Native->new(
                    name => 'do',
                    proc => sub ($ctx, @exprs) { $ctx->strand->do_block( \@exprs ) },
                    is_operative => true,
                ),

                'yield' => Native->new(
                    name => 'yield',
                    proc => sub ($ctx, $expr) { $ctx->strand->yield( $expr ) },
                    is_operative => true,
                ),

                'let' => Native->new(
                    name => 'let',
                    proc => sub ($ctx, $name, $value) { $ctx->strand->bind( $name, $value ) },
                    is_operative => true,
                ),

                'defun' => Native->new(
                    name => 'defun',
                    proc => sub ($ctx, $name, $params, $body) {
                        return $ctx->strand->bind(
                            $name,
                            Lambda->new(
                                name   => $name,
                                params => $params,
                                body   => $body,
                                env    => $ctx->strand->current_env,
                            )
                        )
                    },
                    is_operative => true,
                ),

                ## -------------------------------------------------------------
                ## Channels
                ## -------------------------------------------------------------

                '$$' => Native->new(
                    name => '$$',
                    proc => sub ($ctx) { $ctx->strand->return_value( $ctx ) },
                    is_operative => true,
                ),

                'spawn' => Native->new(
                    name => 'spawn',
                    proc => sub ($ctx, $expr) { $ctx->strand->spawn_pid( $expr ) },
                    is_operative => true,
                ),

                'recv' => Native->new(
                    name => 'recv',
                    proc => sub ($ctx, @args) { $ctx->strand->read_from_channel( @args ) },
                    is_operative => true,
                ),

                'send' => Native->new(
                    name => 'send',
                    proc => sub ($ctx, @args) { $ctx->strand->write_to_channel( @args ) },
                    is_operative => true,
                ),

                ## -------------------------------------------------------------
                ## TTY
                ## -------------------------------------------------------------

                '*stdin' => Native->new(
                    name => '*stdin',
                    proc => sub ($ctx) { $ctx->strand->return_value( $ctx->strand->host->stdin ) },
                    is_operative => true,
                ),

                '*stdout' => Native->new(
                    name => '*stdout',
                    proc => sub ($ctx) { $ctx->strand->return_value( $ctx->strand->host->stdout ) },
                    is_operative => true,
                ),

                '<>' => Native->new(
                    name => '<>',
                    proc => sub ($ctx) { $ctx->strand->read_from_channel( $ctx->strand->host->stdin ) },
                    is_operative => true,
                ),
                'print' => Native->new(
                    name => 'print',
                    proc => sub ($ctx, $expr) {
                        $ctx->strand->write_to_channel( $ctx->strand->host->stdout, $expr )
                    },
                    is_operative => true,
                ),
                'say' => Native->new(
                    name => 'say',
                    proc => sub ($ctx, $expr) {
                        $ctx->strand->write_to_channel( $ctx->strand->host->stdout, Cons->of( Sym->new(ident => '~'), $expr, Str->new(raw => "\n") ) )
                    },
                    is_operative => true,
                ),

            }
        )
    }

    method run ($kont) {
        my $main = $self->spawn( $kont );

        while (true) {
            my $pid = shift @pids;
            #say "Flushing channel for ",$pid->to_string,' @ ',$pid->strand->steps;
            #say '-' x 80;
            $pid->channel->flush if $pid->channel->has_pending;
            #say "BEFORE: ",$pid->channel->DUMP;
            #say '-' x 80;
            #say "Running ... ",$pid->to_string,' @ ',$pid->strand->steps;
            #say '-' x 80;
            my @trace  = $pid->strand->resume;
            #say '-' x 80;
            #say "AFTER: ",$pid->channel->DUMP;
            #say '-' x 80;

            if ($trace[-1]->isa('Error')) {
                say "Error ... ",$pid->to_string,' @ ',$pid->strand->steps;
                warn $trace[-1]->error, "\n";
                last unless @pids;
                next;
            }

            if ($trace[-1]->isa('Halt')) {
                say "Halting ... ",$pid->to_string,' @ ',$pid->strand->steps;
                last unless @pids;
            } else {
                #say "Yielding ... ",$pid->to_string,' @ ',$pid->strand->steps;
                push @pids => $pid;
            }
            #say '=' x 80;
            #my $x = <>;
        }

        return $main->strand->trace;
    }
}


my $host = Runtime->new;

my $exprs = $host->parse(q[

(defun PingPong (kind) (do
    (let msg (recv))
    (let count (car  msg))
    (let $pong (cdar msg))
    (say (~ "Got " count " from " $pong " in " ($$)))
    (if (== count 0)
        (say (~ "... Game Over at " kind " in " ($$)))
        (if (== count 1)
            (do
                (send $pong (list 0 ($$)))
                (say (~ "Game Over at " kind " in " ($$)))
            )
            (do
                (send $pong (list (- count 1) ($$)))
                (yield (PingPong kind))
            )
        )
    )
))

(let $ping (spawn (PingPong :ping)))
(let $pong (spawn (PingPong :pong)))

(send $ping (list 10 $pong))

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

my @trace = $host->run( $compiled );

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


(defun fact (n)
    (if (== n 0) 1
        (* n (fact (- n 1)))))

(defun fib (n)
    (if (< n 2) n
        (+ (fib (- n 2)) (fib (- n 1)))))

(say (~ "FACT/FIB=" (fact (fib 6))))



(defun echo ()
    (do
        (let msg (recv))
        (say (~ "GOT: " msg " in " ($$)))
        (if (eq msg ":q") ()
            (yield (echo)))))

(let $echo1 (spawn (echo)))
(let $echo2 (spawn (echo)))

(send $echo2 "Hello World")
(send $echo1 "Hello World")
(send $echo2 "Goodbye World")
(send $echo1 ":q")
(send $echo2 ":q")














