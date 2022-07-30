# The modules that we need here, with their full identities
use highlighter:ver<0.0.12>:auth<zef:lizmat>;
use Files::Containing:ver<0.0.13>:auth<zef:lizmat>;
use as-cli-arguments:ver<0.0.4>:auth<zef:lizmat>;
use Edit::Files:ver<0.0.4>:auth<zef:lizmat>;
use Git::Blame::File:ver<0.0.2>:auth<zef:lizmat>;
use JSON::Fast:ver<0.17>:auth<cpan:TIMOTIMO>;

# Defaults for highlighting on terminals
my constant BON  = "\e[1m";   # BOLD ON
my constant BOFF = "\e[22m";  # RESET

# Make sure we remember if there's a human watching (terminal connected)
my $isa-tty := $*OUT.t;

# Set up default extension sets
my constant %exts =
  '#c'        => <c h hdl>,
  '#c++'      => <cpp cxx hpp hxx>,
  '#markdown' => <md markdown>,
  '#perl'     => ('', <pl pm t>).flat.List,
  '#python'   => <py>,
  '#raku'     => ('', <raku rakumod rakutest rakudoc nqp t pm6 pl6 pod6 t6>
                 ).flat.List,
  '#ruby'     => <rb>,
  '#text'     => ('', <txt>).flat.List,
  '#yaml'     => <yaml yml>,
;

# Known extensions
my constant @known-extensions = %exts.values.flat.unique.sort;

# Place to keep tagged configurations
my $config-file := $*HOME.add('.rak-config.json');

# Add "s" if number is not 1, for error messages
my sub s($elems) { $elems == 1 ?? "" !! "s" }

# Sane way of quitting
my sub meh($message) { exit note $message }

# Quit if unexpected named arguments hash
my sub meh-if-unexpected(%_) {
    meh "Unexpected option{"s" if %_.elems != 1}: &as-cli-arguments(%_)" if %_;
}

# Is a needle a simple Callable?
my $is-simple-Callable;

# Return string before marker, or string if no marker
my sub before(Str:D $string, Str:D $marker) {
    with $string.index($marker) {
        $string.substr(0,$_)
    }
    else {
        $string
    }
}

# Return named variables in order of specification on the command line
my sub original-nameds() {
    @*ARGS.map: {
        .starts-with('--/')
          ?? before(.substr(3), '=')
          !! .starts-with('--' | '-/')
            ?? before(.substr(2), '=')
            !! .starts-with('-') && $_ ne '-'
              ?? before(.substr(1), '=')
              !! Empty
    }
}

# Return extension of filename, if any
my sub extension(str $filename) {
    with rindex($filename, '.') {
        substr($filename, $_ + 1)
    }
    else {
        ""
    }
}

# Message for humans on STDERR
my sub human-on-stdin(--> Nil) {
    note "Reading from STDIN, please enter source and ^D when done:";
}

# Return object to call .lines on from STDIN
my sub stdin-source() {
    # handle humans
    if $*IN.t {
        human-on-stdin;
        $*IN.slurp(:enc<utf8-c8>).lines
    }
    else {
        $*IN.lines
    }
}

# Process all alternate names / values into a Map and remove them
my sub named-args(%args, *%wanted) {
    Map.new: %wanted.kv.map: -> $name, $keys {
        if $keys =:= True {
            Pair.new($name, %args.DELETE-KEY($name))
              if %args.EXISTS-KEY($name);
        }
        orwith $keys.first: { %args.EXISTS-KEY($_) }, :k {
            Pair.new($name, %args.DELETE-KEY($keys.AT-POS($_)))
        }
        elsif %args.EXISTS-KEY($name) {
            Pair.new($name, %args.DELETE-KEY($name))
        }
    }
}

# Add any lines before / after in a result
role delimiter { has $.delimiter }
my sub add-before-after($io, @initially-selected, int $before, int $after) {
    my str @lines = $io.lines(:enc<utf8-c8>);
    @lines.unshift: "";   # make 1-base indexing natural
    my int $last-linenr = @lines.end;

    my int8 @seen;
    my $selected := IterationBuffer.CREATE;
    for @initially-selected {
        my int $linenr = .key;
        if $before {
            for max($linenr - $before, 1) ..^ $linenr -> int $_ {
                $selected.push:
                  Pair.new($_, @lines.AT-POS($_) but delimiter('-'))
                  unless @seen.AT-POS($_)++;
            }
        }

        $selected.push: Pair.new(.key, .value but delimiter(':'))
          unless @seen.AT-POS($linenr)++;

        if $after {
            for $linenr ^.. min($linenr + $after, $last-linenr ) -> int $_ {
                $selected.push:
                  Pair.new($_, @lines.AT-POS($_) but delimiter('-'))
                  unless @seen.AT-POS($_)++;
            }
        }
    }

    $selected.List
}
# Add any lines until any paragraph boundary
my sub add-paragraph($io, @initially-selected) {
    my str @lines = $io.lines(:enc<utf8-c8>);
    @lines.unshift: "";   # make 1-base indexing natural
    my int $last-linenr = @lines.end;

    my int8 @seen;
    my @selected is List = @initially-selected.map: {
        my int $linenr = .key;
        my int $pos = $linenr;
        my $selected := IterationBuffer.CREATE;
        while --$pos
          && !(@seen.AT-POS($pos)++)
          && @lines.AT-POS($pos) -> $line {
            $selected.unshift: Pair.new($pos, $line but delimiter('-'));
        }

        $selected.push: Pair.new(.key, .value but delimiter(':'))
          unless @seen.AT-POS($linenr)++;

        if $linenr < $last-linenr {
            $pos = $linenr;
            while ++$pos < $last-linenr
              && !(@seen.AT-POS($pos)++)
              && @lines.AT-POS($pos) -> $line {
                $selected.push:
                  Pair.new($pos, $line but delimiter('-'));
            }
            $selected.push:
              Pair.new($pos, @lines.AT-POS($pos) but delimiter('-'))
              unless @seen.AT-POS($pos)++;
        }
        $selected.Slip
    }
    @selected
}

# Return prelude from --repository and --module parameters
my sub prelude(%_) {
    my $prelude = "";
    if %_<I>:delete -> \libs {
        $prelude = libs.map({"use lib '$_'; "}).join;
    }
    if %_<M>:delete -> \modules {
        $prelude ~= modules.map({"use $_; "}).join;
    }
    $prelude
}

# Pre-process non literal string needles, return Callable if possible
my sub codify($needle, %_?) {
    $needle.starts-with('/') && $needle.ends-with('/')
      ?? $needle.EVAL
      !! $needle.starts-with('{') && $needle.ends-with('}')
        ?? (prelude(%_) ~ 'my $ = -> $_ ' ~ $needle).EVAL
        !! $needle.starts-with('*.')
          ?? (prelude(%_) ~ $needle).EVAL
          !! $needle
}

# Change list of conditions into a Callable for :file
my sub codify-extensions(@extensions) {
    -> $_ { extension($_) (elem) @extensions }
}

# Set up the --help handler
use META::constants:ver<0.0.2>:auth<zef:lizmat> $?DISTRIBUTION;
my sub HELP($text, @keys, :$verbose) {
    my $SCRIPT := $*PROGRAM.basename;
    my $header := "$SCRIPT - " ~ DESCRIPTION;
    say $header;
    say "-" x $header.chars;
    say $isa-tty
      ?? $text.lines.map({
              !.starts-with(" ") && .ends-with(":") ?? BON ~ $_ ~ BOFF !! $_
         }).join("\n")
      !! $text;

    if $verbose {
        say "";
        say CREDITS;
        say "";
        say "Thank you for using $SCRIPT!";
    }
}

# Allow --no-foo as an alternative to --/foo
$_ = .subst(/^ '--' no '-' /, '--/') for @*ARGS;

# Entry point for CLI processing
my proto sub MAIN(|) is export {*}

# Make sure we can do --help and --version
use CLI::Version:ver<0.0.4>:auth<zef:lizmat>  $?DISTRIBUTION, &MAIN, 'long';
use CLI::Help:ver<0.0.3>:auth<zef:lizmat> %?RESOURCES, &MAIN, &HELP, 'long';

# Main handler
my multi sub MAIN(*@specs, *%n) {  # *%_ causes compilation issues
    my %config := $config-file.e ?? from-json($config-file.slurp) !! { }

    # Saving config
    if %n<save>:delete -> $option {
        if %n {
            if %n.grep({
                $_ eq '!' || (.starts-with('[') && .ends-with(']')) with .value
            }) -> @reps { 
                meh "Can only have one option with replacement: @reps.map({
                    '"' ~ .key ~ '"'
                }).join(", ") were given" if @reps > 1;
            }
            %config{$option} := %n;
        }
        else {
            %config{$option}:delete;
        }
        $config-file.spurt: to-json %config, :!pretty, :sorted-keys;
        say %n
          ?? "Saved option '--$option' as: " ~ as-cli-arguments(%n)
          !! "Removed option '--$option'";
        exit;
    }

    # Show what we have
    elsif %n<list-custom-options>:delete {
        meh-if-unexpected(%n);

        my $format := '%' ~ %config.keys>>.chars.max ~ 's: ';
        for %config.sort(*.key.fc) -> (:$key, :value(%args)) {
            say sprintf($format,$key) ~ as-cli-arguments(%args);
        }
        exit;
    }

    my sub is-default($value) {
        $value.starts-with('[') && $value.ends-with(']')
    }

    # Recursively translate any custom parameters
    my sub translate($option, $original-value) {
        if %config{$option} -> %adding {
            %n{$option}:delete;

            # no specific value given
            if Bool.ACCEPTS($original-value) {

                # activate option
                if $original-value {
                    for %adding -> (:$key, :$value) {
                        $value eq '!'
                          ?? meh("Must specify a value for $option for $key")
                          !! translate(
                               $key,
                               is-default($value)
                                 ?? $value.substr(1, *-1)
                                 !! $value
                             );
                    }
                }
                # de-activate option
                else {
                    %n{.key}:delete for %adding;
                }
            }

            # some specific value given
            else {
                for %adding -> (:$key, :$value) {
                    translate(
                      $key,
                      $value eq '!' || is-default($value)
                        ?? $original-value
                        !! $value
                    )
                }
            }
        }
        elsif %n{$option}:!exists {
            %n{$option} = $original-value;
        }
    }
    translate($_, %n{$_}) for original-nameds;

    # What did we do?
    if %n<list-expanded-options>:delete {
        say as-cli-arguments(%n);
        exit;
    }

    # Set up output file if needed
    temp $*OUT;
    with %n<output-file>:delete -> $path {
        $*OUT = open($path, :w) if $path ne "-";
    }

    # Set up pager if necessary
    if %n<pager>:delete // %*ENV<RAK_PAGER> -> \pager {
        pager =:= True
          ?? meh("Must specify a specific pager to use: --pager=foo")
          !! ($*OUT = (run pager.words, :in).in);
    }

    # Start looking at actual actionable options
    my $needle = %n<pattern>:delete // @specs.shift;
    meh "Must at least specify a pattern" without $needle;

    # Pre-process non literal string needles
    $needle = codify($needle, %n);
    $is-simple-Callable := Callable.ACCEPTS($needle) && !Regex.ACCEPTS($needle);

    # Handle --smartcase
    %n<ignorecase> = !$needle.contains(/ <:upper> /)
      if Str.ACCEPTS($needle)
      && (%n<ignorecase>:!exists)
      && (%n<smartcase>:delete);

    # Reading from STDIN
    my $root := @specs.head;
    if ($root && $root eq '-') || !$*IN.t  {
        meh "Specified '$root' while reading from STDIN"
          if $root && $root ne '-';
        meh "Can not specify paths while reading from STDIN"
          if @specs > 1;
        ($is-simple-Callable
          ?? (%n<json-per-file>:delete)
            ?? &stdin-json-per-file
            !! (%n<json-per-line>:delete)
              ?? &stdin-json-per-line
              !! &stdin
          !! &stdin
        )($needle, %n);

        # Done
        $*OUT.close;  # in case we're running a pager
        exit;
    }

    # Not reading from STDIN, files are pre-specified
    my $seq := do if %n<files-from>:delete -> $from {
        meh "Cannot specify --files-from with path specification: @specs[]"
          if @specs;
        $from eq "-" ?? $*IN.lines !! $from.IO.lines
    }

    # Need to figure out which files to check
    else {
        my %additional = named-args %n, :follow-symlinks, :file :dir;
        if %additional<file>:exists {
            ...
        }
        elsif %n<extensions>:delete -> $extensions {
            if $extensions.starts-with('#') {
                if %exts{$extensions} -> @exts {
                    %additional<file> := codify-extensions(@exts);
                }
                else {
                    meh "No extensions known for '$extensions'";
                }
            }
            else {
                %additional<file> := codify-extensions($extensions.split(','));
            }
        }
        elsif %n<known-extensions>:delete {
            %additional<file> := codify-extensions @known-extensions;
        }

        # Paths are pre-specified
        if %n<paths-from>:delete -> $from {
            meh "Cannot specify --paths-from with path specification: @specs[]"
              if @specs;

            ( 
              $from eq "-" ?? $*IN.lines !! $from.IO.lines
            ).&hyperize(1,%n<degree>).map: { paths($_, |%additional).Slip }
        }

        # Paths from parameters
        else {
            @specs.unshift(".") unless @specs;
            @specs == 1
              ?? paths(@specs.head, |%additional)
              !! @specs.&hyperize(1,%n<degree>).map: {
                     paths($_, |%additional).Slip
                 }
        }
    }

    # Want to go edit
    if %n<edit>:delete -> $editor {
        go-edit-files($editor, $needle, $seq.sort(*.fc), %n);
    }
    
    # Just match on filenames
    elsif %n<find>:delete {
        %n<show-line-number> //= False;
        stdin($needle, %n, $seq);
    }

    # Need sorted filename list
    else {
        # Embedded in vim
        my &handle := do if %n<vimgrep>:delete {
            vimgrep($needle, %n, $seq);
        }

        # Code to run as a needle
        elsif $is-simple-Callable {
            %n<modify-files>:delete
              ?? &modify-files
              !! (%n<json-per-file>:delete)
                ?? &produce-json-per-file
                !! (%n<json-per-line>:delete)
                  ?? &produce-json-per-line
                  !! (%n<blame-per-line>:delete)
                    ?? &produce-blame-per-line
                    !! (%n<count-only>:delete)
                      ?? &count-only
                      !! (%n<files-with-matches>:delete)
                        ?? &files-only
                        !! &want-lines  # XXX
        }

        # Needle is either string or regex
        else {
            %n<count-only>:delete
              ?? &count-only
              !! (%n<files-with-matches>:delete)
                ?? &files-only
                !! &want-lines
        }
        handle($needle, $seq.sort(*.fc), %n);
        if $is-simple-Callable {
            $_() with $needle.callable_for_phaser('LAST');
        }
    }

    # In case we're running a pager
    $*OUT.close;
}

# Edit / Inspect some files
my sub go-edit-files($editor, $needle, @paths, %_ --> Nil) {
    CATCH { meh .message }

    my $files-with-matches := %_<files-with-matches>:delete;
    my %ignore             := named-args %_, :ignorecase :ignoremark;
    my %additional =
      |(named-args %_, :max-count, :type, :batch, :degree),
      |%ignore;
    meh-if-unexpected(%_);

    edit-files ($files-with-matches
      ?? files-containing($needle, @paths, :files-only, |%additional)
      !! files-containing($needle, @paths, |%additional).map: {
             my $path := .key;
             .value.map({
                 $path => .key + 1 => columns(.value, $needle, |%ignore).head
             }).Slip
         }
      ),
      :editor(Bool.ACCEPTS($editor) ?? Any !! $editor)
}

# Replace contents of files using the given Callable
my sub modify-files(&needle, @paths, %_ --> Nil) {
    my $batch   := %_<batch>:delete;
    my $degree  := %_<degree>:delete;
    my $dryrun  := %_<dryrun>:delete;
    my $verbose := %_<verbose>:delete;

    my $backup = %_<backup>:delete;
    $backup = ".bak" if $backup<> =:= True;
    $backup = ".$backup" if $backup && !$backup.starts-with('.');
    meh-if-unexpected(%_);

    my @files-changed;
    my int $nr-changed;
    my int $nr-removed;

    $_() with &needle.callable_for_phaser('FIRST');
    my $NEXT := &needle.callable_for_phaser('NEXT');
    @paths.&hyperize($batch, $degree).map: -> $path {
        my str @lines;
        my int $lines-changed;
        my int $lines-removed;

        my $io := $path.IO;
        for $io.slurp.lines(:!chomp) {
            my $result := needle($_);
            if $result =:= True || $result =:= Empty {
                @lines.push: $_;
            }
            elsif $result =:= False {
                ++$lines-removed;
            }
            elsif $result eq $_ {
                @lines.push: $_;
            }
            else {
                @lines.push: $result.join;
                ++$lines-changed;
            }
        }
        if $lines-changed || $lines-removed {
            unless $dryrun {
                if $backup {
                    $io.spurt(@lines.join)
                      if $io.rename($io.sibling($io.basename ~ $backup));
                }
                else {
                    $io.spurt: @lines.join;
                }
            }
            @files-changed.push: ($io, $lines-changed, $lines-removed);
            $nr-changed += $lines-changed;
            $nr-removed += $lines-removed;
        }
        $NEXT() if $NEXT;
    }

    my $nr-files = @files-changed.elems;
    my $fb = "Processed @paths.elems() file&s(@paths.elems)";
    $fb ~= ", $nr-files file&s($nr-files) changed"     if $nr-files;
    $fb ~= ", $nr-changed line&s($nr-changed) changed" if $nr-changed;
    $fb ~= ", $nr-removed line&s($nr-removed) removed" if $nr-removed;

    if $verbose {
        $fb ~= "\n";
        for @files-changed -> ($io, $nr-changed, $nr-removed) {
            $fb ~= "$io.relative():";
            $fb ~= " $nr-changed changes" if $nr-changed;
            $fb ~= " $nr-removed removals" if $nr-removed;
            $fb ~= "\n";
        }
        $fb ~= "*** no changes where made because of --dryrun ***\n"
          if $dryrun;
        $fb .= chomp;
    }
    elsif $dryrun {
        $fb ~= "\n*** no changes where made because of --dryrun ***";
    }

    say $fb;
}

# Produce JSON per file to check
my sub produce-json-per-file(&needle, @paths, %_ --> Nil) {
    my $batch         := %_<batch>:delete;
    my $degree        := %_<degree>:delete;
    my $show-filename := %_<show-filename>:delete // True;
    meh-if-unexpected(%_);

    $_() with &needle.callable_for_phaser('FIRST');
    my $NEXT := &needle.callable_for_phaser('NEXT');
    for @paths.&hyperize($batch, $degree).map: {
        my $io := .IO;

        if try from-json $io.slurp -> $json {
            if needle($json) -> \result {
                my $filename := $io.relative;
                result =:= True
                  ?? $filename
                  !! $show-filename
                    ?? "$filename: " ~ result
                    !! result
            }
        }
    } {
        say $_;
        $NEXT() if $NEXT;
    }
}

# Produce JSON per line to check
my sub produce-json-per-line(&needle, @paths, %_ --> Nil) {
    my $batch         := %_<batch>:delete;
    my $degree        := %_<degree>:delete;
    my $show-filename := %_<show-filename>:delete // True;

    $_() with &needle.callable_for_phaser('FIRST');
    my $NEXT := &needle.callable_for_phaser('NEXT');
    if %_<count-only>:delete {
        meh-if-unexpected(%_);
        my int $total;

        for @paths.&hyperize($batch, $degree).map: {
            my $io := .IO;
            my int $found;

            for $io.lines -> $line {
                if try from-json $line -> $json {
                    ++$found if needle($json);
                }
            }

            $total += $found;
            "$io.relative(): $found" if $show-filename;
        } {
            say $_;
            $NEXT() if $NEXT;
        }
        say $total;
    }

    else {
        my $show-line-number := %_<show-line-number>:delete // True;
        meh-if-unexpected(%_);

        for @paths.&hyperize($batch, $degree).map: {
            my $io := .IO;
            my int $line-number;

            $io.lines.map(-> $line {
                ++$line-number;
                if try from-json $line -> $json {
                    if needle($json) -> \result {
                        my $filename := $io.relative;
                        my $mess     := result =:= True ?? '' !! ': ' ~ result;
                        $show-filename
                          ?? $show-line-number
                            ?? "$filename:$line-number$mess"
                            !! "$filename$mess"
                          !! $show-line-number
                            ?? "$line-number$mess"
                            !! $mess
                    }
                }
            }).Slip
        } {
            say $_;
            $NEXT() if $NEXT;
        }
    }
}

# Produce Git::Blame::Line per line to check
my sub produce-blame-per-line(&needle, @paths, %_ --> Nil) {
    my $batch         := %_<batch>:delete;
    my $degree        := %_<degree>:delete;
    my $show-filename := %_<show-filename>:delete // True;
    meh-if-unexpected(%_);

    $_() with &needle.callable_for_phaser('FIRST');
    my $NEXT := &needle.callable_for_phaser('NEXT');
    for @paths.&hyperize($batch, $degree).map: -> $filename {
        if try Git::Blame::File.new($filename).lines -> @lines {
            @lines.map(-> $blamer {
                if needle($blamer) -> \result {
                    result =:= True ?? $blamer.Str !! result
                }
            }).Slip
        }
    } {
        say $_;
        $NEXT() if $NEXT;
    }
}

# Only count matches
my sub count-only($needle, @paths, %_ --> Nil) {
    my $files-with-matches := %_<files-with-matches>:delete;
    my %additional := named-args %_,
      :ignorecase, :ignoremark, :invert-match, :type, :batch, :degree;
    meh-if-unexpected(%_);

    my int $files;
    my int $matches;
    my $NEXT := do if $is-simple-Callable {
        $_() with $needle.callable_for_phaser('FIRST');
        $needle.callable_for_phaser('NEXT')
    }
    for files-containing $needle, @paths, :count-only, |%additional {
        ++$files;
        $matches += .value;
        say .key.relative ~ ': ' ~ .value if $files-with-matches;
        $NEXT() if $NEXT;
    }
    say "$matches matches in $files files";
}

# Only show filenames
my sub files-only($needle, @paths, %_ --> Nil) {
    my $nl := %_<file-separator-null>:delete ?? "\0" !! $*OUT.nl-out;
    my %additional := named-args %_,
      :ignorecase, :ignoremark, :invert-match, :type, :batch, :degree;
    meh-if-unexpected(%_);

    if $is-simple-Callable {
        $_() with $needle.callable_for_phaser('FIRST');
        my $NEXT := $needle.callable_for_phaser('NEXT');
        for files-containing $needle, @paths, :files-only, |%additional {
            print .relative ~ $nl;
            $NEXT() if $NEXT;
        }
    }
    else {
        print .relative ~ $nl
          for files-containing $needle, @paths, :files-only, |%additional;
    }
}

# Show lines with highlighting and context
my sub want-lines($needle, @paths, %_ --> Nil) {
    my $ignorecase := %_<ignorecase>:delete;
    my $ignoremark := %_<ignoremark>:delete;
    my $seq := files-containing
      $needle, @paths, :$ignorecase, :$ignoremark, :offset(1),
      |named-args %_, :invert-match, :max-count, :type, :batch, :degree,
    ;

    my Bool() $paragraph;
    my UInt() $before;
    my UInt() $after;

    if %_<paragraph-context>:delete {
        $paragraph := True;
    }
    elsif %_<context>:delete -> $context {
        $before = $after = $context;
    }
    else {
        $before = $_ with %_<before-context>:delete;
        $after  = $_ with %_<after-context>:delete;
    }
    $before = 0 without $before;
    $after  = 0 without $after;
    my $with-context = $paragraph || $before || $after;

    my Bool() $highlight;
    my Bool() $trim;
    my        $break;
    my Bool() $group-matches;
    my Bool() $show-filename;
    my Bool() $show-line-number;
    my Bool() $show-blame;
    my Bool() $only;
    my Int()  $summary-if-larger-than;

    my $human := %_<human>:delete // $isa-tty;
    if $human {
        $highlight = !$is-simple-Callable;
        $break = $group-matches = $show-filename = $show-line-number = True;
        $only  = $show-blame = False;
        $trim  = !$with-context;
        $summary-if-larger-than = 160;
    }

    unless $is-simple-Callable {
        $highlight := $_ with %_<highlight>:delete;
        $only      := $_ with %_<only-matching>:delete;
    }
    $trim       := $_ with %_<trim>:delete;
    $show-blame := $_ with %_<show-blame>:delete;
    $before = $after = 0 if $only;
    $summary-if-larger-than := $_ with %_<summary-if-larger-than>:delete;

    my &show-line;
    if $highlight {
        my Str() $pre = my Str() $post = $_ with %_<highlight-before>:delete;
        $post = $_ with %_<highlight-after>:delete;
        $pre  = $only ?? " " !! BON  without $pre;
        $post = $only ?? ""  !! BOFF without $post;

        &show-line = $trim && !$show-blame
          ?? -> $line {
                 highlighter $line.trim, $needle<>, $pre, $post,
                   :$ignorecase, :$ignoremark, :$only,
                   :$summary-if-larger-than
             }
          !! -> $line {
                 highlighter $line, $needle<>, $pre, $post,
                   :$ignorecase, :$ignoremark, :$only,
                   :$summary-if-larger-than
             }
        ;
    }
    else {
        &show-line = $only
          ?? -> $line { highlighter $line, $needle, "", " ", :$only }
          !! $trim
            ?? *.trim
            !! -> $line { $line }
        ;
    }

    $break            = $_ with %_<break>:delete;
    $group-matches    = $_ with %_<group-matches>:delete;
    $show-filename    = $_ with %_<show-filename>:delete;
    $show-line-number = $_ with %_<show-line-number>:delete;
    meh-if-unexpected(%_);

    unless $break<> =:= False  {
        $break = "" but True
          if Bool.ACCEPTS($break) || ($break.defined && !$break);
    }

    my $show-header = $show-filename && $group-matches;
    $show-filename  = False if $show-header;
    my int $nr-files;

    my $NEXT := do if $is-simple-Callable {
        $_() with $needle.callable_for_phaser('FIRST');
        $needle.callable_for_phaser('NEXT')
    }
    for $seq -> (:key($io), :value(@matches)) {
        say $break if $break && $nr-files++;

        my str $filename = $io.relative;
        my @blames;
        if $show-blame && Git::Blame::File($io) -> $blamer {
            @blames := $blamer.lines;
        }
        say $filename if $show-header;

        if @blames {
            say show-line(@blames[.key - 1].Str)
              for add-before-after($io, @matches, $before, $after);
        }
        elsif $with-context {
            my @selected := $paragraph
              ?? add-paragraph($io, @matches)
              !! add-before-after($io, @matches, $before, $after);
            my $format := '%' ~ (@selected.tail.key.chars) ~ 'd';
            if $show-line-number {
                for @selected {
                    my str $delimiter = .value.delimiter;
                    say ($show-filename ?? $filename ~ $delimiter !! '')
                      ~ sprintf($format, .key)
                      ~ $delimiter
                      ~ show-line(.value);
                }
            }
            elsif $show-filename {
                say $filename ~ .value.delimiter ~ show-line(.value)
                  for @selected;
            }
            else {
                say show-line(.value) for @selected;
            }
        }
        else {
            if $show-line-number {
                my $format := '%' ~ (@matches.tail.key.chars) ~ 'd:';
                for @matches {
                    say ($show-filename ?? $filename ~ ':' !! '')
                      ~ sprintf($format, .key)
                      ~ show-line(.value);
                }
            }
            elsif $show-filename {
                say $filename ~ ':' ~ show-line(.value) for @matches;
            }
            else {
                say show-line(.value) for @matches;
            }
        }
        $NEXT() if $NEXT;
    }
}

# Provide output that can be used by vim to page through
my sub vimgrep($needle, @paths, %_ --> Nil) {
    my $ignorecase := %_<ignorecase>:delete;
    my $ignoremark := %_<ignoremark>:delete;
    my %additional := named-args %_, :max-count, :type, :batch, :degree;
    meh-if-unexpected(%_);

    say $_ for files-containing(
      $needle, @paths, :$ignorecase, :$ignoremark, :offset(1), |%additional
    ).map: {
        my $path := .key.relative;
        .value.map({
            $path
              ~ ':' ~ .key
              ~ ':' ~ columns(.value, $needle, :$ignorecase, :$ignoremark).head
              ~ ':' ~ .value
        }).Slip
    }
}

# Read from STDIN, assume JSON per line
my sub stdin-json-per-file(&needle, %_ --> Nil) {
    meh-if-unexpected(%_);

    human-on-stdin if $*IN.t;
    if try from-json $*IN.slurp(:enc<utf8-c8>) -> $json {
        if needle($json) -> \result {
            say result;
        }
    }
}

# Read from STDIN, assume JSON per line
my sub stdin-json-per-line(&needle, %_ --> Nil) {
    my $count-only       := %_<count-only>:delete;
    my $show-line-number := %_<show-line-number>:delete;
    meh-if-unexpected(%_);

    my int $line-number;
    my int $matches;
    for stdin-source() -> $line {
        ++$line-number;
        if try from-json $line -> $json {
            if needle($json) -> \result {
                $count-only
                  ?? ++$matches
                  !! result =:= True
                    ?? say($line-number)
                    !! $show-line-number
                      ?? say($line-number ~ ': ' ~ result)
                      !! say(result)
            }
        }
    }
    say $matches if $count-only;
}

# Handle general searching on STDIN
my sub stdin($needle, %_, $source = stdin-source --> Nil) {
    my Bool() $highlight;
    my Bool() $trim;
    my Bool() $show-line-number;
    my Bool() $only;
    my Int()  $summary-if-larger-than;

    my UInt() $before = $_ with %_<before-context>:delete;
    my UInt() $after  = $_ with %_<after-context>:delete;
    $before = $after  = $_ with %_<context>:delete;
    $before = 0 without $before;
    $after  = 0 without $after;

    my $human := %_<human>:delete // $isa-tty;
    if $human {
        $highlight = !$is-simple-Callable;
        $show-line-number = !%_<passthru>;
        $only = False;
        $trim = !($before || $after || $is-simple-Callable);
        $summary-if-larger-than = 160;
    }

    $highlight = $_ with %_<highlight>:delete;
    $trim      = $_ with %_<trim>:delete;
    $only      = $_ with %_<only-matching>:delete;
    $before = $after = 0 if $only;
    $show-line-number       = $_ with %_<show-line-number>:delete;
    $summary-if-larger-than = $_ with %_<summary-if-larger-than>:delete;

    my $ignorecase := %_<ignorecase>:delete;
    my $ignoremark := %_<ignoremark>:delete;
    my &show-line;
    if $highlight {
        my Str() $pre = my Str() $post = $_ with %_<highlight-before>:delete;
        $post = $_ with %_<highlight-after>:delete;
        $pre  = $only ?? " " !! BON  without $pre;
        $post = $only ?? ""  !! BOFF without $post;

        &show-line = $trim
          ?? -> $line {
                 highlighter $line.trim, $needle<>, $pre, $post,
                 :$ignorecase, :$ignoremark, :$only,
                 :$summary-if-larger-than
             }
          !! -> $line {
                 highlighter $line, $needle<>, $pre, $post,
                 :$ignorecase, :$ignoremark, :$only,
                 :$summary-if-larger-than
             }
        ;
    }
    else {
        &show-line = $only
          ?? -> $line { highlighter $line, $needle, "", " ", :$only }
          !! $trim
            ?? *.trim
            !! -> $line { $line }
        ;
    }

    my &matcher := do if Callable.ACCEPTS($needle) {
        Regex.ACCEPTS($needle)
          ?? { $needle.ACCEPTS($_) }
          !! $needle
    }
    elsif %_<passthru>:delete {
        -> $ --> True { }
    }
    else {
        my $type := %_<type>:delete // 'contains';
        $type eq 'words'
          ?? *.&has-word($needle, :$ignorecase, :$ignoremark)
          !! $type eq 'starts-with'
            ?? *.starts-with($needle, :$ignorecase, :$ignoremark)
            !! $type eq 'ends-with'
              ?? *.ends-with($needle, :$ignorecase, :$ignoremark)
              !! *.contains($needle, :$ignorecase, :$ignoremark);
    }
    meh-if-unexpected(%_);

    my int $line-number;
    my int $todo-after;
    my str @before;
    for $source<> -> $line {
        ++$line-number;
        if matcher($line) -> \result {
            say @before.shift while @before;
            my $text := result =:= True ?? show-line($line) !! result;
            say $show-line-number ?? ($line-number ~ ':' ~ $text) !! $text;
            $todo-after = $after;
        }
        elsif $todo-after {
            say $show-line-number
              ?? $line-number ~ ':' ~ $line
              !! $line;
            --$todo-after;
        }
        elsif $before {
            @before.shift if @before.elems == $before;
            @before.push: $show-line-number
              ?? $line-number ~ ':' ~ $line
              !! $line;
        }
    }
}

# vim: expandtab shiftwidth=4
