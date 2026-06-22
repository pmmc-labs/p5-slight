
use v5.42;
use utf8;
use open ':std', ':encoding(UTF-8)';
use experimental qw[ class switch ];
use Test::More;

## -----------------------------------------------------------------------------

use constant DEBUG => $ENV{DEBUG} // 0;

# track allocation for informational
# purposes only, this is a hack ;)
our %ALLOCATIONS = ( TERMS => +{}, KONTS => +{}, MISC  => +{} );

# this is for debugging stuff
use Term::ReadKey ();
our $WIDTH = (Term::ReadKey::GetTerminalSize)[0];

## -----------------------------------------------------------------------------
## Terms
## -----------------------------------------------------------------------------

class Term {
    # NOTE: this is only to make sure
    # we are not relying on this anywhere
    use overload '""' => sub (@) { use Carp (); Carp::confess("TERM IS NOT AUTOSTRINGIFIED") };
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

class List :isa(Term) {
    method uncons  { ... }
    method reverse { ... }
    method length  { ... }
}

class Nil :isa(List) {
    sub NIL { state $t = Nil->new }
    method to_string { '()' }
    method is_nil  { true }
    method uncons  { () }
    method reverse { $self }
    method length  { 0 }
}

class Cons :isa(List) {
    field $head :param :reader;
    field $tail :param :reader;

    sub of ($, @args) {
        my $list = Nil->NIL;
        $list = Cons->new( head => (pop @args), tail => $list )
            while @args;
        return $list;
    }

    method length {
        my $len = 0;
        my $l = $self;
        until ($l->is_nil) {
            $len++;
            $l = $l->tail;
        }
        return $len;
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
        blessed $_ ? $_->to_string : die $_
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
    sub TRUE  { state $t = Bool->new( raw => true )  }
    sub FALSE { state $t = Bool->new( raw => false ) }
    method to_string { $raw ? 'true' : 'false' }
}

class Callable :isa(Literal) {
    method has_name       { ... }
    method arity          { ... }
    method is_operative   { ... }
    method is_applicative { ... }
}

class Lambda :isa(Callable) {
    field $params :param :reader;
    field $body   :param :reader;
    field $env    :param :reader;
    field $name   :param :reader = undef;

    method has_name { defined $name }
    method arity    { $params->length }

    method is_operative   { false }
    method is_applicative { true  }

    method to_string { sprintf '(<lambda> %s %s)' => $params->to_string, $body->to_string }
}

class Native :isa(Callable) {
    field $name  :param :reader;
    field $proc  :param :reader;
    field $arity :param :reader = 0;

    ADJUST { $name = Sym->new(ident => $name) }

    method has_name { defined $name }

    field $is_operative :param :reader = false;
    method is_applicative { !$is_operative }

    method to_string { sprintf '#<%s>' => $name->to_string }
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
    field $name :param :reader = undef;

    field @w_buffer :reader;
    field @r_buffer :reader;

    our $ID_SEQ = 0;
    ADJUST { $name //= sprintf '%02d' => ++$ID_SEQ; }

    method can_read    { !! scalar @r_buffer }
    method has_pending { !! scalar @w_buffer }

    method read           { shift @r_buffer }
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

    method bind ($sym, $value) {
        say "HELLO!!! setting ",$sym->to_string;
        $bindings->{ $sym->ident } = $value;
    }

    method derive (%bindings) {
        return Env->new( parent => $self, bindings => \%bindings )
    }

    method DUMP {
        return () unless defined $parent; # do not DUMP the root
        return $parent->DUMP, %$bindings;
    }

    method to_string {
        sprintf 'ENV<%s>' => ($bindings =~ /\(0x(.*)\)/);
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
        say '-' x $WIDTH;
        say sprintf '=> %-12s : %s' => __CLASS__,
            substr((
                defined $self->kont ? $self->kont->to_string : undef
            ) // '!!', 0, ($WIDTH - 20));
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
                return Eval::Expr->new(
                    expr => $expr->head,
                    kont => Apply::Expr->new(
                        args => $expr->tail,
                        kont => $self->kont
                    )
                );
            }
            when ('Sym') {
                my $value = $ctx->strand->current_scope->lookup($expr);
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
        return Eval::Args->new( rest => $args, kont => $next )
    }

    method to_string {
        return sprintf '%s[%s] > %s', __CLASS__, $args->to_string, $self->kont->to_string;
    }
}

class Eval::Args :isa(Kontinue) {
    field $rest :param :reader;
    field $done :param :reader = Nil->NIL;

    method kontinue ($ctx, $value=undef) {
        $self->DEBUG($ctx, rest => $rest, done => $done, '+value' => $value // '?') if ::DEBUG;

        $done = Cons->new( head => $value, tail => $done )
            if defined $value;

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
        $args //= Nil->NIL;
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
                my $params = $self->bind_params( $ctx, $call, $args );
                return $params if $params isa Error;
                return $ctx->strand->wrap_call(
                    $params,
                    $call,
                    $self->kont
                )
            }
            default {
                die "Cannot call => ${call}";
            }
        }
    }

    method to_string {
        return sprintf '%s[%s] > %s', __CLASS__, ($call->has_name ? $call->name->to_string : $call->to_string), $self->kont->to_string;
    }
}

## ...

class Scope::Enter :isa(Kontinue) {
    field $env  :param :reader;

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
    field $depth :param :reader = 1;
    method kontinue ($ctx, $result=undef) {
        $result = Nil->NIL unless defined $result;
        $self->DEBUG($ctx, '+result' => $result) if ::DEBUG;
        $ctx->strand->leave_scope until $depth-- == 0;
        return $ctx->strand->return_value( $result, $self->kont );
    }

    method to_string {
        return sprintf '%s[%d] > %s', __CLASS__, $depth, $self->kont->to_string;
    }
}

class Bind :isa(Kontinue) {
    field $name :param :reader;
    method kontinue ($ctx, $value) {
        $self->DEBUG($ctx, 'name' => $name, '+value' => $value) if ::DEBUG;
        $ctx->strand->current_scope->bind( $name, $value );
        return $ctx->strand->return_value( Nil->NIL, $self->kont );
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
        my $kont = $ctx->strand->host->compile( $ctx->strand->current_scope, [ $expr ] );
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
        return $ctx->strand->return_value( Nil->NIL, $self->kont );
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
                push @stack => +[ Sym->new( ident => 'quote' ) ];
                unshift @tokens => ')';
            }
            given ($token) {
                when (/^\"/)   { push $stack[-1]->@*, Str->new( raw => substr($token, 1, -1) ); }
                when (/^\d+$/) { push $stack[-1]->@*, Num->new( raw => $token+0 ); }
                when ('nil')   { push $stack[-1]->@*, Nil->NIL; }
                when ('true')  { push $stack[-1]->@*, Bool->TRUE; }
                when ('false') { push $stack[-1]->@*, Bool->FALSE; }
                when ('\'(')   { push @stack => +[ Sym->new( ident => 'quote' ) ]; }
                when ('(')     { push @stack => +[]; }
                when (')')     {
                    my $list = pop @stack;
                    push $stack[-1]->@*, (scalar $list->@* > 0)
                        ? Cons->of( $list->@* )
                        : Nil->NIL;
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

class Compiler {
    method compile ($env, $exprs) {
        $self->compile_block($env, $exprs, Halt->new);
    }

    my sub optimize_tail_call ($kont, $depth=1) {
        return __SUB__->( $kont->kont, $depth + $kont->depth )
            if $kont isa Scope::Leave;
        return Scope::Leave->new( kont => $kont, depth => $depth )
    }

    method compile_block ($env, $exprs, $kont) {
        my $next = optimize_tail_call( $kont );
        foreach my $expr (reverse @$exprs) {
            $next = Eval::Expr->new(
                expr => $expr,
                kont => ($next isa Scope::Leave)
                        ? $next
                        : Drop->new( kont => $next ));
        }
        return Scope::Enter->new( env => $env, kont => $next );
    }

    method wrap_call ($env, $call, $kont) {
        Scope::Enter->new(
            env  => $env,
            kont => Eval::Expr->new(
                expr => $call->body,
                kont => optimize_tail_call( $kont )
            )
        )
    }

    method throw_error ($error, $kont) {
        Error->new( error => $error, kont => $kont )
    }

    method return_value ($value, $kont) {
        Return->new( value => $value, kont => $kont )
    }

    method bind ($name, $expr, $kont) {
        Eval::Expr->new(
            expr => $expr,
            kont => Bind->new(
                name => $name,
                kont => $kont
            )
        )
    }

    method conditional ($condition, $if_true, $if_false, $kont) {
        Eval::Expr->new(
            expr => $condition,
            kont => Cond->new(
                if_true  => $if_true,
                if_false => $if_false,
                kont     => $kont,
            )
        )
    }

    method spawn_pid ($expr, $kont) {
        Spawn->new( expr => $expr, kont => $kont )
    }

    method yield ($expr, $kont) {
        Yield->new(
            kont => Eval::Expr->new(
                expr => $expr,
                kont => $kont
            )
        )
    }

    method read_from_channel ($pid, $kont) {
        Eval::Expr->new(
            expr => $pid,
            kont => Chan::Read->new(
                kont => $kont
            )
        )
    }

    method write_to_channel ($pid, $expr, $kont) {
        Eval::Args->new(
            rest => Cons->of( $pid, $expr ),
            kont => Chan::Write->new( kont => $kont )
        )
    }

    ADJUST { $::ALLOCATIONS{MISC}->{ blessed $self }++; }
}

## -----------------------------------------------------------------------------
## Strand (of Execution)
## -----------------------------------------------------------------------------

class Strand {
    field $host  :param :reader;
    field $enter :param :reader;
    field $pid   :param :reader;

    field @trace  :reader;
    field $steps  :reader;
    field @envs   :reader;

    ADJUST {
        $steps = 0;
        $pid = PID->new( id => $pid, strand => $self, channel => Channel->new );
        $::ALLOCATIONS{MISC}->{ blessed $self }++;
    }

    ## -------------------------------------------------------------------------

    method enter_scope ($e) { push @envs => $e }
    method leave_scope      { pop @envs }
    method current_scope    { $envs[-1] }

    ## -------------------------------------------------------------------------

    method prev_kont { $trace[-1] }
    method next_kont { $trace[-1]->kont }

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
            when ('Return') {
                push @trace => $kont->kont;
                return $kont->kont->kontinue( $self->pid, $kont->value );
            }
            default {
                return $kont->kontinue( $self->pid );
            }
        }
    }

    ## -------------------------------------------------------------------------
    ## Helpers to be used in Native subs

    method throw_error ($error, $kont=undef) {
        $host->compiler->throw_error( $error, $kont // $self->next_kont )
    }

    method return_value ($value, $kont=undef) {
        $host->compiler->return_value( $value, $kont // $self->next_kont )
    }

    method wrap_call ($env, $call, $kont) {
        $host->compiler->wrap_call( $env, $call, $kont );
    }

    method do_block ($exprs, $kont=undef) {
        $host->compiler->compile_block( $self->current_scope, $exprs, $kont // $self->next_kont )
    }

    method bind ($name, $expr, $kont=undef) {
        $host->compiler->bind( $name, $expr, $kont // $self->next_kont )
    }

    method conditional ($condition, $if_true, $if_false, $kont=undef) {
        $host->compiler->conditional( $condition, $if_true, $if_false, $kont // $self->next_kont )
    }

    method yield ($expr, $kont=undef) {
        $host->compiler->yield( $expr, $kont // $self->next_kont )
    }

    method read_from_channel ($channel, $kont=undef) {
        $host->compiler->read_from_channel( $channel, $kont // $self->next_kont );
    }

    method write_to_channel ($channel, $expr, $kont=undef) {
        $host->compiler->write_to_channel( $channel, $expr, $kont // $self->next_kont )
    }

    method spawn_pid ($expr, $kont=undef) {
        $host->compiler->spawn_pid( $expr, $kont // $self->next_kont )
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

class Host {
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

                'atom?'     => Native->new( name => 'atom?',     proc => sub ($n) { $n isa Literal  ? Bool->TRUE : Bool->FALSE }),
                'list?'     => Native->new( name => 'list?',     proc => sub ($n) { $n isa List     ? Bool->TRUE : Bool->FALSE }),
                'callable?' => Native->new( name => 'callable?', proc => sub ($n) { $n isa Callable ? Bool->TRUE : Bool->FALSE }),
                'nil?'      => Native->new( name => 'nil?',      proc => sub ($n) { $n isa Nil      ? Bool->TRUE : Bool->FALSE }),
                'num?'      => Native->new( name => 'num?',      proc => sub ($n) { $n isa Num      ? Bool->TRUE : Bool->FALSE }),
                'str?'      => Native->new( name => 'str?',      proc => sub ($n) { $n isa Str      ? Bool->TRUE : Bool->FALSE }),
                'bool?'     => Native->new( name => 'bool?',     proc => sub ($n) { $n isa Bool     ? Bool->TRUE : Bool->FALSE }),
                'tag?'      => Native->new( name => 'tag?',      proc => sub ($n) { $n isa Tag      ? Bool->TRUE : Bool->FALSE }),
                'sym?'      => Native->new( name => 'sym?',      proc => sub ($n) { $n isa Sym      ? Bool->TRUE : Bool->FALSE }),
                'native?'   => Native->new( name => 'native?',   proc => sub ($n) { $n isa Native   ? Bool->TRUE : Bool->FALSE }),
                'lambda?'   => Native->new( name => 'lambda?',   proc => sub ($n) { $n isa Lambda   ? Bool->TRUE : Bool->FALSE }),
                'channel?'  => Native->new( name => 'channel?',  proc => sub ($n) { $n isa Channel  ? Bool->TRUE : Bool->FALSE }),
                'pid?'      => Native->new( name => 'pid?',      proc => sub ($n) { $n isa PID      ? Bool->TRUE : Bool->FALSE }),

                'list'  => Native->new( name => 'list',  proc => sub (@args)  { Cons->of( @args ) }),
                'cons'  => Native->new( name => 'cons',  proc => sub ($h, $t) { Cons->new( head => $h, tail => $t ) }),
                'car'   => Native->new( name => 'car',   proc => sub ($list)  { $list->head }),
                'cdr'   => Native->new( name => 'cdr',   proc => sub ($list)  { $list->tail }),
                'cadr'  => Native->new( name => 'cadr',  proc => sub ($list)  { $list->tail->head }),
                'caar'  => Native->new( name => 'caar',  proc => sub ($list)  { $list->head->head }),
                'cdar'  => Native->new( name => 'cdar',  proc => sub ($list)  { $list->head->tail }),

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
                                env    => $ctx->strand->current_scope
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
                                env    => $ctx->strand->current_scope,
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
                    proc => sub ($ctx, @args) {
                        unshift @args => $ctx->strand->pid if scalar @args == 0;
                        $ctx->strand->read_from_channel( @args );
                    },
                    is_operative => true,
                ),

                'send' => Native->new(
                    name => 'send',
                    proc => sub ($ctx, @args) {
                        unshift @args => $ctx->strand->pid if scalar @args == 1;
                        $ctx->strand->write_to_channel( @args )
                    },
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
        my @done;
        my $main = $self->spawn( $kont );
        while (true) {
            my $pid = shift @pids;
            say ">" x $WIDTH if ::DEBUG;
            say ">> RESUME ".$pid->DUMP if ::DEBUG;
            say ">" x $WIDTH if ::DEBUG;
            $pid->channel->flush if $pid->channel->has_pending;
            my $last = ($pid->strand->resume)[-1];
            if ($last->isa('Error')) {
                say "!" x $WIDTH if ::DEBUG;
                say "!! ERRORED ".$pid->DUMP if ::DEBUG;
                say "!" x $WIDTH if ::DEBUG;
                warn $last->error, "\n";
                last unless @pids;
                next;
            }
            if ($last->isa('Halt')) {
                say "*" x $WIDTH if ::DEBUG;
                say "** HALTING ".$pid->DUMP if ::DEBUG;
                say "*" x $WIDTH if ::DEBUG;
                push @done => $pid;
                last unless @pids;
            } else {
                say "<" x $WIDTH if ::DEBUG;
                say "<< YIELD ".$pid->DUMP if ::DEBUG;
                say "<" x $WIDTH if ::DEBUG;
                push @pids => $pid;
            }
        }
        return @done;
    }
}

## -----------------------------------------------------------------------------

my %SOURCES = (
    'fact'  => q[
        (defun fact (n)
            (if (== n 0) 1
                (* n (fact (- n 1)))))
    ],
    'fib' => q[
        (defun fib (n)
            (if (< n 2) n
                (+ (fib (- n 2)) (fib (- n 1)))))
    ],
    'length' => q[
        (defun length (list)
            (if (nil? list) 0
                (+ 1 (length (cdr list)))))
    ],
    'length-iter' => q[
        (defun length-iter (list count)
            (if (nil? list) count
                (length-iter (cdr list) (+ count 1))))
    ],
    'tail-call-demo' => q[
        (defun tail-call-demo (n)
            (if (== n 0) 0
               (tail-call-demo (- n 1))))
    ],
    'ping-pong' => q[
        (defun PingPong (kind) (do
            (let msg (recv))
            (let count (car  msg))
            (let $pong (cadr msg))
            (say (~ "Got " count " from " $pong " in " ($$)))
            (if (== count 0)
                (say (~ "... Game Over at " kind " in " ($$)))
                (if (== count 1)
                    (do
                        (send $pong (list 0 ($$)))
                        (say (~ "... Game Over at " kind " in " ($$)))
                    )
                    (do
                        (send $pong (list (- count 1) ($$)))
                        (yield (PingPong kind))
                    )))))
    ],
    '--test' => q[

        (defun adder (n m) (+ n m))

        (defun double (n) (adder n n))

        (defun range (b e)
            (if (== b e)
                (cons e nil)
                (cons b (range (+ b 1) e))))

        (defun map (f lst)
            (if (nil? lst) ()
                (cons (f (car lst)) (map f (cdr lst)))))

        (defun grep (f lst)
            (if (nil? lst) ()
                (if (f (car lst))
                    (cons (car lst) (grep f (cdr lst)))
                    (grep f (cdr lst)))))

        (defun reduce (acc f lst)
            (if (nil? lst) acc
                (reduce (f (car lst) acc) f (cdr lst))))

        (defun sum (lst)
            (reduce 0 (lambda (n acc) (+ acc n)) lst))

        (defun product (lst)
            (reduce 1 (lambda (n acc) (* acc n)) lst))

        (defun Calculator (reply-to)
            (do
                (let op (recv))
                (if (native? op)
                (do
                    (let n  (recv))
                    (let m  (recv))
                    (send reply-to (op n m))
                    (yield (Calculator reply-to))
                ) ())))

    ],
);

my %TESTS = (
    'fact'           => q[ (fact 6) ],
    'fib'            => q[ (fib 6) ],
    'length'         => q[ (length (list 1 2 3 4 5)) ],
    'length-iter'    => q[ (length-iter (list 1 2 3 4 5) 0) ],
    'tail-call-demo' => q[ (tail-call-demo 10) ],
    'ping-pong'      => q[
        (let $ping (spawn (PingPong :ping)))
        (let $pong (spawn (PingPong :pong)))
        (send $ping (list 10 $pong))
    ],
    '--test' => q[
        (let reply-to ($$))
        (let calc (spawn (Calculator reply-to)))

        ;; many silly ways to calculate 30
        (list
            30
            (+ 10 20)
            (+ (* 2 5) 20)
            (+ 10 (* 4 5))
            (+ (* 2 5) (* 4 5))
            (+ (* 2 (- 9 4)) (* 4 5))
            (+ (* 2 (- 9 4)) (* 4 (+ 4 1)))
            (adder 10 20)
            (adder (double 5) 20)
            (adder 10 (* (double 2) 5))
            (adder (fib 6) 22)
            (adder (fib 8) (+ 1 (double 4)))
            (- (fact 6) (+ (* (fact 3) 100) 90))
            ((lambda (n m) (+ n m)) 10 20)
            ((lambda (f n m) (f n m)) + 10 20)
            (+ (length (list 0 1 2 3 4 5 6 7 8 9)) 20)
            (length (range 1 30))
            (+ (length (range 1 10)) (length (range 1 (* 4 5))))
            (+ (product (list 2 1 5)) (sum (list 2 4 6 8)))
            (sum (list 4 (fib 8) (- (fact 3) 1)))
            (+ (sum (range 0 (fib 6))) (- 2 8))
            (sum (grep
                    (lambda (x) (>= x 10))
                    (list 0 2 10 4 7 20 3 1)))
            (sum (map
                    (lambda (x) (if (<= x 20) x 0))
                    (list 100 25 10 411 75 20 35 1000)))
            (do
                (send ($$) 10)
                (send ($$) 20)
                (let x (recv))
                (let y (recv))
                (+ x y))
            (do
                (send calc +)
                (send calc 10)
                (send calc 20)
                (recv))
            (do
                (send calc *)
                (send calc 2)
                (send calc 5)
                (send calc +)
                (send calc (recv))
                (send calc 20)
                (let result (recv))
                (send calc :exit)
                result)
        )
    ],
);

my %ASSERTS = (
    'fact'           => sub ($pids) { is($pids->[0]->strand->prev_kont->result->raw, 720, '... fact demo got expected 720') },
    'fib'            => sub ($pids) { is($pids->[0]->strand->prev_kont->result->raw, 8,   '... fib demo got expected 8') },
    'length'         => sub ($pids) { is($pids->[0]->strand->prev_kont->result->raw, 5,   '... length demo got expected 5') },
    'length-iter'    => sub ($pids) { is($pids->[0]->strand->prev_kont->result->raw, 5,   '... length-iter demo got expected 5') },
    'tail-call-demo' => sub ($pids) { is($pids->[0]->strand->prev_kont->result->raw, 0,   '... tail-call-demo demo got expected 0') },
    'ping-pong'      => sub ($pids) {
        is(scalar(@$pids), 3, '... got the expected number of PIDs');
        isa_ok($_, 'PID') foreach @$pids;
        my ($main, $pong, $ping) = @$pids;

        my $pong_kont = ($pong->strand->trace)[1];
        isa_ok($pong_kont, 'Eval::Expr');
        isa_ok($pong_kont->expr, 'Cons');
        isa_ok($pong_kont->expr->head, 'Sym');
        is($pong_kont->expr->head->ident, 'PingPong', '... got PingPong');
        isa_ok($pong_kont->expr->tail, 'Cons');
        isa_ok($pong_kont->expr->tail->head, 'Tag');
        is($pong_kont->expr->tail->head->ident, ':pong', '... got :pong');

        my $ping_kont = ($pong->strand->trace)[1];
        isa_ok($ping_kont, 'Eval::Expr');
        isa_ok($ping_kont->expr, 'Cons');
        isa_ok($ping_kont->expr->head, 'Sym');
        is($ping_kont->expr->head->ident, 'PingPong', '... got PingPong');
        isa_ok($ping_kont->expr->tail, 'Cons');
        isa_ok($ping_kont->expr->tail->head, 'Tag');
        is($ping_kont->expr->tail->head->ident, ':pong', '... got :ping');

    },
    '--test' => sub ($pids) {
        my ($pid) = grep { $_->id == 0 } @$pids;

        my $result = $pid->strand->prev_kont->result;
        return fail("Expected cons list for results of --test not ".$result->to_string)
            unless $result isa Cons;

        my sub unpack_results ($r) {
            return $r->raw if $r isa Literal;
            my @out;
            until ($r->is_nil) {
                my $got = $r->head;
                if ($got isa Literal) {
                    push @out => $got->raw;
                } elsif ($got isa List) {
                    push @out => [ map { __SUB__->($_) } $got->uncons ];
                } else {
                    die "NOPE!"
                }
                $r = $r->tail;
            }
            return @out;
        }

        my @got      = unpack_results( $result );
        my @expected = (30) x (scalar @got);

        foreach my $expected (@expected) {
            my $got = shift @got;
            if (ref $expected) {
                is_deeply($got, $expected, "... expected [".(join ', ', @$expected)."] - got [".(join ', ', @$got)."]");
            } else {
                is($got, $expected, "... expected $expected - got $got");
            }
        }

        ok(scalar @got == 0, '... we should be out of values to expect');

        return true;
    }
);

## -----------------------------------------------------------------------------

my $WHICH  = $ARGV[0] // '--test';
my $SOURCE = join "\n\n", $SOURCES{ $WHICH } // $WHICH, $TESTS{ $WHICH } // ();

if ($WHICH eq '--test') {
    $SOURCE = join "\n\n" => @SOURCES{qw[ fib fact length length-iter ]}, $SOURCE;
}

say '=' x $WIDTH;
say "SOURCE:";
say '=' x $WIDTH;
say $SOURCE;

my $host = Host->new;

say '=' x $WIDTH;
say "PARSED:";
say '=' x $WIDTH;
my $exprs = $host->parse($SOURCE);
say '    - ', $_->to_string foreach @$exprs;

say '=' x $WIDTH;
say "COMPILED:";
say '=' x $WIDTH;
my $compiled = $host->compile( $host->root_env, $exprs );
say '    +  ', $compiled;

say '=' x $WIDTH;
say "RUNNING:";
say '=' x $WIDTH;
my @pids = $host->run( $compiled );

die "Expected some PIDs here!" unless @pids;

say '=' x $WIDTH;
say "ASSERTION:";
say '=' x $WIDTH;
if (($ASSERTS{ $WHICH } // sub ($) { true })->(\@pids)) {
    say "   + ASSERTION PASSED FOR $WHICH";
} else {
    say "   - ASSERTION FAILED FOR $WHICH";
}

say '=' x $WIDTH;
say "COMPLETED:";
say '=' x $WIDTH;
foreach my $pid (@pids) {
    say '  > ',$pid->DUMP,' ended in '.$pid->strand->steps.' steps with ',$pid->strand->prev_kont->to_string;
    say join "\n" => map {
        sprintf '[%s]' => join ', ' => map { $_->to_string } @$_
    } $pid->strand->envs;
}

say '=' x $WIDTH;
say "ALLOCATIONS:";
say '=' x $WIDTH;
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
say '=' x $WIDTH;


pass('... ran successfully');
done_testing;

