package App::perlbrew;
use strict;
use warnings;
use 5.008;
use Getopt::Long ();
use File::Spec::Functions qw( catfile );

our $VERSION = "0.21";
our $CONF;

my $ROOT         = $ENV{PERLBREW_ROOT} || "$ENV{HOME}/perl5/perlbrew";
my $CONF_FILE    = catfile( $ROOT, 'Conf.pm' );
my $CURRENT_PERL = $ENV{PERLBREW_PERL};

sub current_perl { $CURRENT_PERL || '' }

sub BASHRC_CONTENT() {
    return <<'RC';
if [[ -f $HOME/.perlbrew/init ]]; then
    source $HOME/.perlbrew/init
fi

__perlbrew_reinit () {
    if [[ ! -d $HOME/.perlbrew ]]; then
        mkdir -p $HOME/.perlbrew
    fi

    echo '# DO NOT EDIT THIS FILE' >| $HOME/.perlbrew/init
    command perlbrew env $1 >> $HOME/.perlbrew/init
    source $HOME/.perlbrew/init
    __perlbrew_set_path
}

__perlbrew_set_path () {
    [[ -z "$PERLBREW_ROOT" ]] && return 1
    hash -d perl 2>/dev/null
    export PATH_WITHOUT_PERLBREW=$(perl -e 'print join ":", grep { index($_, $ENV{PERLBREW_ROOT}) } split/:/,$ENV{PATH};')
    export PATH=$PERLBREW_PATH:$PATH_WITHOUT_PERLBREW
}
__perlbrew_set_path

perlbrew () {
    local exit_status
    local short_option
    export SHELL

    if [[ `echo $1 | awk 'BEGIN{FS=""}{print $1}'` = '-' ]]; then
        short_option=$1
        shift
    else
        short_option=""
    fi

    case $1 in
        (use)
            if [[ -z "$2" ]] ; then
                if [[ -z "$PERLBREW_PERL" ]] ; then
                    echo "No version in use; defaulting to system"
                else
                    echo "Using $PERLBREW_PERL version"
                fi
            elif [[ -x "$PERLBREW_ROOT/perls/$2/bin/perl" || "$2" = "system" ]]; then
                eval $(command perlbrew $short_option env $2)
                __perlbrew_set_path
            elif [[ -x "$PERLBREW_ROOT/perls/perl-$2/bin/perl" ]]; then
                eval $(command perlbrew $short_option env "perl-$2")
                __perlbrew_set_path
            else
                echo "$2 is not installed" >&2
                exit_status=1
            fi
            ;;

        (switch)
              if [[ -n "$2" ]] ; then
                  if [[ -x "$PERLBREW_ROOT/perls/$2/bin/perl" ]]; then
                      perlbrew $short_option use $2
                      __perlbrew_reinit $2
                  elif [[ -x "$PERLBREW_ROOT/perls/perl-$2/bin/perl" ]]; then
                      perlbrew $short_option use "perl-$2"
                      __perlbrew_reinit "perl-$2"
                  else
                      echo "$2 is not installed" >&2
                      exit_status=1
                  fi
              else
                if [[ -z "$PERLBREW_PERL" ]] ; then
                    echo "No version in use; defaulting to system"
                else
                    echo "Using $PERLBREW_PERL version"
                fi
              fi
              ;;

        (off)
            unset PERLBREW_PERL
            command perlbrew $short_option off

            __perlbrew_reinit
            ;;

        (*)
            command perlbrew $short_option $*
            exit_status=$?
            ;;
    esac
    hash -r
    return ${exit_status:-0}
}

RC

}

sub CSHRC_CONTENT {
    return <<'CSHRC';
if ( $?PERLBREW_SKIP_INIT == 0 ) then
    if ( -f $HOME/.perlbrew/init ) then
        source $HOME/.perlbrew/init
    endif
endif

setenv PATH_WITHOUT_PERLBREW `perl -e 'print join ":", grep { index($_, $ENV{PERLBREW_ROOT}) } split/:/,$ENV{PATH};'`
setenv PATH ${PERLBREW_PATH}:${PATH_WITHOUT_PERLBREW}
CSHRC
}

# File::Path::Tiny::mk
sub mkpath {
    my ($path,$mask) = @_;
    return 2 if -d $path;
    if (-e $path) { $! = 20;return; }
    $mask ||= '0777'; # Perl::Critic == Integer with leading zeros at ...
    $mask = oct($mask) if substr($mask,0,1) eq '0';
    require File::Spec;
    my ($progressive, @parts) = File::Spec->splitdir($path);
    if (!$progressive) {
        $progressive = File::Spec->catdir($progressive, shift(@parts));
    }
    if(!-d $progressive) {
        mkdir($progressive, $mask) or return;
    }
    for my $part (@parts) {
        $progressive = File::Spec->catdir($progressive,$part);
        if (!-d $progressive) {
            mkdir($progressive, $mask) or return;
        }
    }
    return 1 if -d $path;
    return;
}

# File::Path::Tiny::rm
sub rmpath {
    my ($path) = @_;
    if (-e $path && !-d $path) { $! = 20;return; }
    return 2 if !-d $path;
    opendir(DIR, $path) or return;
    my @contents = grep { $_ ne '.' && $_ ne '..' } readdir(DIR);
    closedir DIR;
    require File::Spec if @contents;
    for my $thing (@contents) {
        my $long = File::Spec->catdir($path, $thing);
        if (!-l $long && -d $long) {
            rmpath($long) or return;
        }
        else {
            unlink $long or return;
        }
    }
    rmdir($path) or return;
    return 1;
}

sub uniq(@) {
    my %a;
    grep { ++$a{$_} == 1 } @_;
}

{
    my @command;
    sub http_get {
        my ($url, $header, $cb) = @_;

        if (ref($header) eq 'CODE') {
            $cb = $header;
            $header = undef;
        }

        if (! @command) {
            my @commands = (
                # curl's --fail option makes the exit code meaningful
                [qw( curl --silent --location --fail )],
                [qw( wget --no-check-certificate --quiet -O - )],
            );
            for my $command (@commands) {
                my $program = $command->[0];
                if (! system("$program --version >/dev/null 2>&1")) {
                    @command = @$command;
                    last;
                }
            }
            die "You have to install either curl or wget\n"
                unless @command;
        }

        open my $fh, '-|', @command, $url
            or die "open() for '@command $url': $!";

        local $/;
        my $body = <$fh>;
        close $fh;
        die 'Page not retrieved; HTTP error code 400 or above.'
            if $command[0] eq 'curl' # Exit code is 22 on 404s etc
            and $? >> 8 == 22; # exit code is packed into $?; see perlvar
        die 'Server issued an error response.'
            if $command[0] eq 'wget' # Exit code is 8 on 404s etc
            and $? >> 8 == 8;

        return $cb ? $cb->($body) : $body;
    }
}

sub new {
    my($class, @argv) = @_;

    my %opt = (
        force => 0,
        quiet => 1,
        D => [],
        U => [],
        A => [],
    );

    # build a local @ARGV to allow us to use an older
    # Getopt::Long API in case we are building on an older system
    local (@ARGV) = @argv;

    Getopt::Long::Configure(
        'pass_through',
        'no_ignore_case',
        'bundling',
    );

    Getopt::Long::GetOptions(
        \%opt,

        'force|f!',
        'notest|n!',
        'quiet|q!',
        'verbose|v',
        'as=s',
        'help|h',
        'version',
        # options passed directly to Configure
        'D=s@',
        'U=s@',
        'A=s@',

        'j=i'
    )
      or run_command_help(1);

    # fix up the effect of 'bundling'
    foreach my $flags (@opt{qw(D U A)}) {
        foreach my $value(@{$flags}) {
            $value =~ s/^=//;
        }
    }

    $opt{args} = \@ARGV;

    return bless \%opt, $class;
}

sub env {
    my ($self, $name) = @_;
    return $ENV{$name} if $name;
    return \%ENV;
}

sub path_with_tilde {
    my ($self, $dir) = @_;
    my $home = $self->env('HOME');
    $dir =~ s/^$home/~/ if $home;
    return $dir;
}

sub is_shell_csh {
    my ($self) = @_;
    return 1 if $self->env('SHELL') =~ /(t?csh)/;
    return 0;
}

sub run {
    my($self) = @_;
    $self->run_command($self->get_args);
}

sub get_args {
    my ( $self ) = @_;
    return @{ $self->{args} };
}

sub run_command {
    my ( $self, $x, @args ) = @_;
    $self->{log_file} ||= "$ROOT/build.log";
    if($self->{version}) {
        $x = 'version';
    }
    elsif(!$x) {
        $x = 'help';
        @args = (0, $self->{help} ? 2 : 0);
    }
    elsif($x eq 'help') {
        @args = (0, 2);
    }

    my $s = $self->can("run_command_$x");
    unless ($s) {
        $x =~ s/-/_/;
        $s = $self->can("run_command_$x");
    }

    die "Unknown command: `$x`. Typo?\n" unless $s;

    # Assume 5.12.3 means perl-5.12.3, for example.
    if ($x =~ /\A(?:switch|use|install|env)\Z/ and my $dist = shift @args) {
        if ($dist =~ /\A(?:\d+\.)*\d+\Z/) {
            unshift @args, "perl-$dist";
        }
        else {
            unshift @args, $dist;
        }
    }

    $self->$s(@args);
}

sub run_command_version {
    my ( $self ) = @_;
    my $package = ref $self;
    my $version = $self->VERSION;
    print <<"VERSION";
$0  - $package/$version
VERSION
}

sub run_command_help {
    my ($self, $status, $verbose) = @_;
    require Pod::Usage;
    Pod::Usage::pod2usage(-verbose => $verbose||0, -exitval => (defined $status ? $status : 1));
}

sub run_command_available {
    my ( $self, $dist, $opts ) = @_;

    my @available = $self->get_available_perls(@_);
    my @installed = $self->installed_perls(@_);

    my $is_installed;
    for my $available (@available) {
        $is_installed = 0;
        for my $installed (@installed) {
            my $name = $installed->{name};
            my $cur  = $installed->{is_current};
            if ( $available eq $installed->{name} ) {
                $is_installed = 1;
                last;
            }
        }
        print $is_installed ? 'i ' : '  ', $available, "\n";
    }
}

sub get_available_perls {
    my ( $self, $dist, $opts ) = @_;

    my $url = "http://www.cpan.org/src/README.html";
    my $html = http_get( $url, undef, undef );

    my @available_versions;

    for ( split "\n", $html ) {
        push @available_versions, $1
          if m|<td><a href="http://www.cpan.org/src/.+?">(.+?)</a></td>|;
    }
    s/\.tar\.gz// for @available_versions;

    return @available_versions;
}

sub run_command_init {
    my $self = shift;
    my $HOME = $self->env('HOME');

    mkpath($_) for (
        "$HOME/.perlbrew",
        "$ROOT/perls", "$ROOT/dists", "$ROOT/build", "$ROOT/etc",
        "$ROOT/bin"
    );

    open BASHRC, "> $ROOT/etc/bashrc";
    print BASHRC BASHRC_CONTENT;
    close BASHRC;

    open CSHRC, "> $ROOT/etc/cshrc";
    print CSHRC CSHRC_CONTENT;
    close CSHRC;

    my ( $shrc, $yourshrc );
    if ( $self->is_shell_csh) {
        $shrc     = 'cshrc';
        $self->env("SHELL") =~ m/(t?csh)/;
        $yourshrc = $1 . "rc";
    }
    else {
        $shrc = $yourshrc = 'bashrc';
    }

    system("$0 env @{[ $self->current_perl ]}> ${HOME}/.perlbrew/init");

    $self->run_command_symlink_executables;

    my $root_dir = $self->path_with_tilde($ROOT);

    print <<INSTRUCTION;
Perlbrew environment initiated, required directories are created under

    $root_dir

Paste the following line to the end of your ~/.${yourshrc} and start a
new shell, perlbrew should be up and fully functional from there:

    source $root_dir/etc/${shrc}

For further instructions, simply run `perlbrew` to see the help message.

Enjoy perlbrew at \$HOME!!
INSTRUCTION

}

sub run_command_install_perlbrew {
    my $self = shift;
    require File::Copy;

    my $executable = $0;

    unless (File::Spec->file_name_is_absolute($executable)) {
        $executable = File::Spec->rel2abs($executable);
    }

    my $target = catfile($ROOT, "bin", "perlbrew");
    if ($executable eq $target) {
        print "You are already running the installed perlbrew:\n\n    $executable\n";
        exit;
    }

    mkpath("$ROOT/bin");
    File::Copy::copy($executable, $target);
    chmod(0755, $target);

    my $path = $self->path_with_tilde($target);

    print <<HELP;
The perlbrew is installed as:

    $path

You may trash the downloaded $executable from now on.

HELP

    $self->run_command_init();
    return;
}

sub do_install_git {
    my $self = shift;
    my $dist = shift;

    my $dist_name;
    my $dist_git_describe;
    my $dist_version;
    require Cwd;
    my $cwd = Cwd::cwd();
    chdir $dist;
    if (`git describe` =~ /v((5\.\d+\.\d+(?:-RC\d)?)(-\d+-\w+)?)$/) {
        $dist_name = 'perl';
        $dist_git_describe = "v$1";
        $dist_version = $2;
    }
    chdir $cwd;
    my $dist_extracted_dir = File::Spec->rel2abs( $dist );
    $self->do_install_this($dist_extracted_dir, $dist_version, "$dist_name-$dist_version");
    return;
}

sub do_install_url {
    my $self = shift;
    my $dist = shift;

    my $dist_name = 'perl';
    # need the period to account for the file extension
    my ($dist_version) = $dist =~ m/-([\d.]+(?:-RC\d+)?|git)\./;
    my ($dist_tarball) = $dist =~ m{/([^/]*)$};

    my $dist_tarball_path = "$ROOT/dists/$dist_tarball";
    my $dist_tarball_url  = $dist;
    $dist = "$dist_name-$dist_version"; # we install it as this name later

    if ($dist_tarball_url =~ m/^file/) {
        print "Installing $dist from local archive $dist_tarball_url\n";
        $dist_tarball_url =~ s/^file:\/+/\//;
        $dist_tarball_path = $dist_tarball_url;
    }
    else {
        print "Fetching $dist as $dist_tarball_path\n";
        http_get(
            $dist_tarball_url,
            undef,
            sub {
                my ($body) = @_;
                open my $BALL, "> $dist_tarball_path" or die "Couldn't open $dist_tarball_path: $!";
                print $BALL $body;
                close $BALL;
            }
        );
    }

    my $dist_extracted_path = $self->do_extract_tarball($dist_tarball_path);
    $self->do_install_this($dist_extracted_path, $dist_version, $dist);
    return;
}

sub do_extract_tarball {
    my $self = shift;
    my $dist_tarball = shift;

    # Was broken on Solaris, where GNU tar is probably
    # installed as 'gtar' - RT #61042
    my $tarx =
        ($^O eq 'solaris' ? 'gtar ' : 'tar ') .
        ( $dist_tarball =~ m/bz2$/ ? 'xjf' : 'xzf' );
    my $extract_command = "cd $ROOT/build; $tarx $dist_tarball";
    die "Failed to extract $dist_tarball" if system($extract_command);
    $dist_tarball =~ s{.*/([^/]+)\.tar\.(?:gz|bz2)$}{$1};
    return "$ROOT/build/$dist_tarball"; # Note that this is incorrect for blead
}

sub do_install_blead {
    my $self = shift;
    my $dist = shift;

    my $dist_name           = 'perl';
    my $dist_git_describe   = 'blead';
    my $dist_version        = 'blead';

    # We always blindly overwrite anything that's already there,
    # because blead is a moving target.
    my $dist_tarball = 'blead.tar.gz';
    my $dist_tarball_path = "$ROOT/dists/$dist_tarball";
    print "Fetching $dist_git_describe as $dist_tarball_path\n";
    http_get(
        "http://perl5.git.perl.org/perl.git/snapshot/$dist_tarball",
        undef,
        sub {
            my ($body) = @_;
            open my $BALL, "> $dist_tarball_path" or die "Couldn't open $dist_tarball_path: $!";
            print $BALL $body;
            close $BALL;
        }
    );

    # Returns the wrong extracted dir for blead
    $self->do_extract_tarball($dist_tarball_path);

    local *DIRH;
    opendir DIRH, "$ROOT/build" or die "Couldn't open $ROOT/build: $!";
    my @contents = readdir DIRH;
    closedir DIRH or warn "Couldn't close $ROOT/build: $!";
    my @candidates = grep { m/^perl-[0-9a-f]{7,8}$/ } @contents;
    # Use a Schwartzian Transform in case there are lots of dirs that
    # look like "perl-$SHA1", which is what's inside blead.tar.gz,
    # so we stat each one only once.
    @candidates =   map  { $_->[0] }
                    sort { $b->[1] <=> $a->[1] } # descending
                    map  { [ $_, (stat("$ROOT/build/$_"))[9] ] }
                        @candidates;
    my $dist_extracted_dir = "$ROOT/build/$candidates[0]"; # take the newest one
    $self->do_install_this($dist_extracted_dir, $dist_version, "$dist_name-$dist_version");
    return;
}

sub do_install_release {
    my $self = shift;
    my $dist = shift;

    my ($dist_name, $dist_version) = $dist =~ m/^(.*)-([\d.]+(?:-RC\d+)?)$/;
    my $mirror = $self->conf->{mirror};
    my $header = $mirror ? { 'Cookie' => "cpan=$mirror->{url}" } : undef;
    my $html = http_get("http://search.cpan.org/dist/$dist", $header);

    my ($dist_path, $dist_tarball) =
        $html =~ m[<a href="(/CPAN/authors/id/.+/(${dist}.tar.(gz|bz2)))">Download</a>];
    die "ERROR: Cannot find the tarball for $dist\n"
        if !$dist_path and !$dist_tarball;

    my $dist_tarball_path = "${ROOT}/dists/${dist_tarball}";
    my $dist_tarball_url  = "http://search.cpan.org${dist_path}";

    if (-f $dist_tarball_path) {
        print "Use the previously fetched ${dist_tarball}\n";
    }
    else {
        print "Fetching $dist as $dist_tarball_path\n";
        http_get(
            $dist_tarball_url,
            $header,
            sub {
                my ($body) = @_;
                open my $BALL, "> $dist_tarball_path";
                print $BALL $body;
                close $BALL;
            }
        );
    }
    my $dist_extracted_path = $self->do_extract_tarball($dist_tarball_path);
    $self->do_install_this($dist_extracted_path,$dist_version, $dist);
    return;
}

sub run_command_install {
    my ( $self, $dist, $opts ) = @_;
    $self->{dist_name} = $dist;

    unless ($dist) {
        $self->run_command_install_perlbrew();
        return
    }

    my $help_message = "Unknown installation target \"$dist\", abort.\nPlease see `perlbrew help` for the instruction on using the install command.\n\n";

    my ($dist_name, $dist_version) = $dist =~ m/^(.*)-([\d.]+(?:-RC\d+)?|git)$/;
    if (!$dist_name || !$dist_version) { # some kind of special install
        if (-d "$dist/.git") {
            $self->do_install_git($dist);
        }
        if (-f $dist) {
            $self->do_install_archive($dist);
        }
        elsif ($dist =~ m/^(?:https?|ftp|file)/) { # more protocols needed?
            $self->do_install_url($dist);
        }
        elsif ($dist =~ m/(?:perl-)?blead$/) {
            $self->do_install_blead($dist);
        }
        else {
            print $help_message;
        }
    }
    elsif ($dist_name eq 'perl') {
        $self->do_install_release($dist);
    }
    else {
        print $help_message;
    }

    return;
}

sub do_install_archive {
    my $self = shift;
    my $dist_tarball_path = shift;
    my $dist_version;
    my $installation_name;

    if ($dist_tarball_path =~ m{perl-?(5.+)\.tar\.(gz|bz2)\Z}) {
        $dist_version = $1;
        $installation_name = "perl-${dist_version}";
    }

    unless ($dist_version && $installation_name) {
        die "Unable to determin perl version from archive filename.\n\nThe archive name should look like perl-5.x.y.tar.gz or perl-5.x.y.tar.bz2\n";
    }

    my $dist_extracted_path = $self->do_extract_tarball($dist_tarball_path);
    $self->do_install_this($dist_extracted_path, $dist_version, $installation_name);
    return;
}

sub do_install_this {
    my ($self, $dist_extracted_dir, $dist_version, $as) = @_;

    my @d_options = @{ $self->{D} };
    my @u_options = @{ $self->{U} };
    my @a_options = @{ $self->{A} };
    $as = $self->{as} if $self->{as};

    unshift @d_options, qq(prefix=$ROOT/perls/$as);
    push @d_options, "usedevel" if $dist_version =~ /5\.1[13579]|git/;
    print "Installing $dist_extracted_dir into " . $self->path_with_tilde("$ROOT/perls/$as") . "\n";
    print <<INSTALL if $self->{quiet} && !$self->{verbose};

This could take a while. You can run the following command on another shell to track the status:

  tail -f @{[ $self->path_with_tilde($self->{log_file}) ]}

INSTALL

    my $configure_flags = '-des';
    $configure_flags = '-de';
    # Test via "make test_harness" if available so we'll get
    # automatic parallel testing via $HARNESS_OPTIONS. The
    # "test_harness" target was added in 5.7.3, which was the last
    # development release before 5.8.0.
    my $test_target = "test";
    if ($dist_version =~ /^5\.(\d+)\.(\d+)/
        && ($1 >= 8 || $1 == 7 && $2 == 3)) {
        $test_target = "test_harness";
    }
    local $ENV{TEST_JOBS}=$self->{j}
      if $test_target eq "test_harness" && ($self->{j}||1) > 1;

    my $make = "make " . ($self->{j} ? "-j$self->{j}" : "");
    my @install = $self->{notest} ? "make install" : ("make $test_target", "make install");
    @install    = join " && ", @install unless($self->{force});

    my $cmd = join ";",
    (
        "cd $dist_extracted_dir",
        "rm -f config.sh Policy.sh",
        "patchperl",
        "sh Configure $configure_flags " .
            join( ' ',
                ( map { qq{'-D$_'} } @d_options ),
                ( map { qq{'-U$_'} } @u_options ),
                ( map { qq{'-A$_'} } @a_options ),
            ),
        $dist_version =~ /^5\.(\d+)\.(\d+)/
            && ($1 < 8 || $1 == 8 && $2 < 9)
                ? ("$^X -i -nle 'print unless /command-line/' makefile x2p/makefile")
                : (),
        $make,
        @install
    );
    $cmd = "($cmd) >> '$self->{log_file}' 2>&1 ";

    print "$cmd\n" if $self->{verbose};

    delete $ENV{$_} for qw(PERL5LIB PERL5OPT);

    if (!system($cmd)) {
        unless (-e "$ROOT/perls/$as/bin/perl") {
            $self->run_command_symlink_executables($as);
        }

        print <<SUCCESS;
Installed $dist_extracted_dir as $as successfully. Run the following command to switch to it.

  perlbrew switch $as

SUCCESS
    }
    else {
        print <<FAIL;
Installing $dist_extracted_dir failed. See $self->{log_file} to see why.
If you want to force install the distribution, try:

  perlbrew --force install $self->{dist_name}

FAIL
    }
    return;
}

sub format_perl_version {
    my $self    = shift;
    my $version = shift;
    return sprintf "%d.%d.%d",
      substr( $version, 0, 1 ),
      substr( $version, 2, 3 ),
      substr( $version, 5 );

}

sub installed_perls {
    my $self    = shift;

    my @result;

    for (<$ROOT/perls/*>) {
        next if m/current/;
        my ($name) = $_ =~ m/\/([^\/]+$)/;
        my $executable = catfile($_, 'bin', 'perl');

        push @result, {
            name => $name,
            version => $self->format_perl_version(`$executable -e 'print \$]'`),
            is_current => (current_perl eq $name)
        };
    }

    my $current_perl_executable = `which perl`;
    $current_perl_executable =~ s/\n$//;

    my $current_perl_executable_version;
    for ( uniq grep { -f $_ && -x $_ } map { "$_/perl" } split(":", $self->env('PATH')) ) {
        $current_perl_executable_version =
          $self->format_perl_version(`$_ -e 'print \$]'`);
        push @result, {
            name => $_,
            version => $current_perl_executable_version,
            is_current => $current_perl_executable && ($_ eq $current_perl_executable)
        } unless index($_, $ROOT) == 0;
    }

    return @result;
}

# Return a hash of PERLBREW_* variables
sub perlbrew_env {
    my ($self, $perl) = @_;

    my %env = (
        PERLBREW_VERSION => $VERSION,
        PERLBREW_PATH => "$ROOT/bin",
        PERLBREW_ROOT => $ROOT
    );

    if ($perl) {
        if(-d "$ROOT/perls/$perl/bin") {
            $env{PERLBREW_PERL} = $perl;
            $env{PERLBREW_PATH} .= ":$ROOT/perls/$perl/bin";
        }
    }
    elsif ( $self->env("PERLBREW_PERL") ) {
        $env{PERLBREW_PERL} = $self->env("PERLBREW_PERL");
        $env{PERLBREW_PATH} .= ":$ROOT/perls/$env{PERLBREW_PERL}/bin";
    }

    return %env;
}

sub run_command_list {
    my $self = shift;

    for my $i ( $self->installed_perls ) {
        print $i->{is_current} ? '* ': '  ',
            $i->{name},
            (index($i->{name}, $i->{version}) < $[) ? " ($i->{version})" : "",
            "\n";
    }
}

sub run_command_use {
    my $self = shift;
    my $perl = shift;

    my $shell = $self->env('SHELL');
    my %env = ($self->perlbrew_env($perl), PERLBREW_SKIP_INIT => 1);

    my $command = "env ";
    while (my ($k, $v) = each(%env)) {
        $command .= "$k=$v ";
    }
    $command .= " $shell";

    print "\nA sub-shell is launched with $perl as the activated perl. Run 'exit' to finish it.\n\n";
    exec($command);
}

sub run_command_switch {
    my ( $self, $dist, $alias ) = @_;

    unless ( $dist ) {
        my $current = $self->current_perl;
        printf "Currently switched %s\n",
            ( $current ? "to $current" : 'off' );
        return;
    }

    die "Cannot use for alias something that starts with 'perl-'\n"
      if $alias && $alias =~ /^perl-/;

    my $vers = $dist;
    if (-x $dist) {
        $alias = 'custom' unless $alias;
        my $bin_dir = "$ROOT/perls/$alias/bin";
        my $perl = catfile($bin_dir, 'perl');
        mkpath($bin_dir);
        unlink $perl;
        symlink $dist, $perl;
        $dist = $alias;
        $vers = "$vers as $alias";
    }

    die "${dist} is not installed\n" unless -d "$ROOT/perls/${dist}";

    local $ENV{PERLBREW_PERL} = $dist;
    my $HOME = $self->env('HOME');

    mkpath("${HOME}/.perlbrew");
    system("$0 env $dist > ${HOME}/.perlbrew/init");

    print "Switched to $vers. To use it immediately, run this line in this terminal:\n\n    exec @{[ $self->env('SHELL') ]}\n\n";
}

sub run_command_off {
    my $self = shift;
    my $HOME = $self->env("HOME");

    mkpath("${HOME}/.perlbrew");
    system("env PERLBREW_PERL= $0 env > ${HOME}/.perlbrew/init");

    print "\nperlbrew is switched off. Please exit this shell and start a new one to make it effective.\n";
    print "To immediately make it effective, run this line in this terminal:\n\n    exec @{[ $self->env('SHELL') ]}\n\n";
}

sub run_command_mirror {
    my($self) = @_;
    print "Fetching mirror list\n";
    my $raw = http_get("http://search.cpan.org/mirror");
    my $found;
    my @mirrors;
    foreach my $line ( split m{\n}, $raw ) {
        $found = 1 if $line =~ m{<select name="mirror">};
        next if ! $found;
        last if $line =~ m{</select>};
        if ( $line =~ m{<option value="(.+?)">(.+?)</option>} ) {
            my $url  = $1;
            my $name = $2;
            $name =~ s/&#(\d+);/chr $1/seg;
            $url =~ s/&#(\d+);/chr $1/seg;
            push @mirrors, { url => $url, name => $name };
        }
    }

    require ExtUtils::MakeMaker;
    my $select;
    my $max = @mirrors;
    my $id  = 0;
    while ( @mirrors ) {
        my @page = splice(@mirrors,0,20);
        my $base = $id;
        printf "[% 3d] %s\n", ++$id, $_->{name} for @page;
        my $remaining = $max - $id;
        my $ask = "Select a mirror by number or press enter to see the rest "
                . "($remaining more) [q to quit, m for manual entry]";
        my $val = ExtUtils::MakeMaker::prompt( $ask );
        if ( ! length $val )  { next }
        elsif ( $val eq 'q' ) { last }
        elsif ( $val eq 'm' ) {
            my $url  = ExtUtils::MakeMaker::prompt("Enter the URL of your CPAN mirror:");
            my $name = ExtUtils::MakeMaker::prompt("Enter a Name: [default: My CPAN Mirror]") || "My CPAN Mirror";
            $select = { name => $name, url => $url };
            last;
        }
        elsif ( not $val =~ /\s*(\d+)\s*/ ) {
            die "Invalid answer: must be 'q', 'm' or a number\n";
        }
        elsif (1 <= $val and $val <= $max) {
            $select = $page[ $val - 1 - $base ];
            last;
        }
        else {
            die "Invalid ID: must be between 1 and $max\n";
        }
    }
    die "You didn't select a mirror!\n" if ! $select;
    print "Selected $select->{name} ($select->{url}) as the mirror\n";
    my $conf = $self->conf;
    $conf->{mirror} = $select;
    $self->_save_conf;
    return;
}

sub run_command_env {
    my($self, $perl) = @_;

    my %env = $self->perlbrew_env($perl);

    if ($self->env('SHELL') =~ /(ba|z|\/)sh$/) {
        while (my ($k, $v) = each(%env)) {
            print "export $k=$v\n";
        }
    }
    else {
        while (my ($k, $v) = each(%env)) {
            print "setenv $k $v\n";
        }
    }
}

sub run_command_symlink_executables {
    my($self, @perls) = @_;

    unless (@perls) {
        @perls = map { m{/([^/]+)$} } grep { -d $_ && ! -l $_ } <$ROOT/perls/*>;
    }

    for my $perl (@perls) {
        for my $executable (<$ROOT/perls/$perl/bin/*>) {
            my ($name, $version) = $executable =~ m/bin\/(.+?)(5\.\d.*)?$/;
            system("ln -fs $executable $ROOT/perls/$perl/bin/$name") if $version;
        }
    }
}

sub run_command_install_cpanm {
    my ($self, $perl) = @_;
    my $body = http_get('https://github.com/miyagawa/cpanminus/raw/master/cpanm');

    open my $CPANM, '>', "$ROOT/bin/cpanm" or die "cannot open file($ROOT/bin/cpanm): $!";
    print $CPANM $body;
    close $CPANM;
    chmod 0755, "$ROOT/bin/cpanm";
    print "cpanm is installed to $ROOT/bin/cpanm\n" if $self->{verbose};
}

sub run_command_exec {
    my ($self, @args) = @_;

    for my $i ( $self->installed_perls ) {
        my %env = $self->perlbrew_env($i->{name});
        next if !$env{PERLBREW_PERL};

        my $command = "";

        while ( my($name, $value) = each %env) {
            $command .= "$name=$value ";
        }

        $command .= ' PATH=${PERLBREW_PATH}:${PATH} ';
        $command .= "; " . join " ", map { quotemeta($_) } @args;

        print "$i->{name}\n==========\n";
        system "$command\n";
        print "\n\n";
        # print "\n<===\n\n\n";
    }
}

sub run_command_clean {
    my ($self) = @_;
    my @build_dirs = <$ROOT/build/*>;

    for my $dir (@build_dirs) {
        print "Remove $dir\n";
        rmpath($dir);
    }

    print "\nDone\n";
}

sub conf {
    my($self) = @_;
    $self->_get_conf if ! $CONF;
    return $CONF;
}

sub _save_conf {
    my($self) = @_;
    require Data::Dumper;
    open my $FH, '>', $CONF_FILE or die "Unable to open conf ($CONF_FILE): $!";
    my $d = Data::Dumper->new([$CONF],['App::perlbrew::CONF']);
    print $FH $d->Dump;
    close $FH;
}

sub _get_conf {
    my($self) = @_;

    if ( ! -e $CONF_FILE ) {
        local $CONF = {} if ! $CONF;
        $self->_save_conf;
    }

    open my $FH, '<', $CONF_FILE or die "Unable to open conf ($CONF_FILE): $!\n";
    my $raw = do { local $/; my $rv = <$FH>; $rv };
    close $FH;

    my $rv = eval $raw;
    if ( $@ ) {
        warn "Error loading conf: $@\n";
        $CONF = {};
        return;
    }
    $CONF = {} if ! $CONF;
    return;
}

1;

__END__

=encoding utf8

=head1 NAME

App::perlbrew - Manage perl installations in your $HOME

=head1 SYNOPSIS

    # Initialize
    perlbrew init

    # Pick a preferred CPAN mirror
    perlbrew mirror

    # See what is available
    perlbrew available

    # Install some Perls
    perlbrew install 5.14.0
    perlbrew install perl-5.8.1
    perlbrew install perl-5.13.6

    # See what were installed
    perlbrew list

    # Switch perl in the $PATH
    perlbrew switch perl-5.12.2
    perl -v

    # Temporarily use another version only in current shell.
    perlbrew use perl-5.8.1
    perl -v

    # Switch to a certain perl executable not managed by perlbrew.
    perlbrew switch /usr/bin/perl

    # Or turn it off completely. Useful when you messed up too deep.
    perlbrew off

    # Use 'switch' command to turn it back on.
    perlbrew switch perl-5.12.2

    # Exec something with all perlbrew-ed perls
    perlbrew exec perl -E 'say $]'

=head1 DESCRIPTION

perlbrew is a program to automate the building and installation of
perl in the users HOME. At the moment, it installs everything to
C<~/perl5/perlbrew>, and requires you to tweak your PATH by including a
bashrc/cshrc file it provides. You then can benefit from not having
to run 'sudo' commands to install cpan modules because those are
installed inside your HOME too. It's a completely separate perl
environment.

=head1 INSTALLATION

To use C<perlbrew>, it is required to install C<curl> or C<wget>
first. C<perlbrew> depends on one of this two external commmands to be
there in order to fetch files from the internet.

The recommended way to install perlbrew is to run these statements in
your shell:

    curl -L http://xrl.us/perlbrewinstall | bash

After that, C<perlbrew> installs itself to C<~/perl5/perlbrew/bin>,
and you should follow the instruction on screen to setup your
C<.bashrc> or C<.cshrc> to put it in your PATH.

The downloaded perlbrew is a self-contained standalone program that
embeds all non-core modules it uses. It should be runnable with perl
5.8 or later versions of perl.

This installer also installs a packed version of C<patchperl> to
C<~/perl5/perlbrew/bin>, which is required to build old perls.

The directory C<~/perl5/perlbrew> will contain all install perl
executables, libraries, documentations, lib, site_libs. If you need to
install C<perlbrew>, and the perls it brews, into somewhere else
because, say, your HOME has limited quota, you can do that by setting
a C<PERLBREW_ROOT> environment variable before running the installer:

    export PERLBREW_ROOT=/opt/perlbrew
    curl -L http://xrl.us/perlbrewinstall | bash

You may also install perlbrew from CPAN:

    cpan App::perlbrew

However, please make sure not to run this with one of the perls brewed
with perlbrew. It's the best to turn perlbrew off before you run that,
if you're upgrading.

    perlbrew off
    cpan App::perlbrew

You should always use system cpan (like /usr/bin/cpan) to install
C<App::perlbrew> because then it will be installed under a system PATH
like C</usr/bin>, which is not affected by perlbrew C<switch> or
C<use> command.

However, it is still recommended to let C<perlbrew> install itself. It's
easier, and it works better.

=head1 USAGE

Please read the program usage by running

    perlbrew

(No arguments.) To read a more detailed one:

    perlbrew -h

=head1 PROJECT DEVELOPMENT

perlbrew project uses github
L<http://github.com/gugod/App-perlbrew/issues> and RT
<https://rt.cpan.org/Dist/Display.html?Queue=App-perlbrew> for issue
tracking. Issues sent to these two systems will eventually be reviewed
and handled.

=head1 AUTHOR

Kang-min Liu  C<< <gugod@gugod.org> >>

=head1 COPYRIGHT

Copyright (c) 2010, 2011 Kang-min Liu C<< <gugod@gugod.org> >>.

=head1 LICENCE

The MIT License

=head1 CONTRIBUTORS

See L<https://github.com/gugod/App-perlbrew/contributors>

=head1 DISCLAIMER OF WARRANTY

BECAUSE THIS SOFTWARE IS LICENSED FREE OF CHARGE, THERE IS NO WARRANTY
FOR THE SOFTWARE, TO THE EXTENT PERMITTED BY APPLICABLE LAW. EXCEPT WHEN
OTHERWISE STATED IN WRITING THE COPYRIGHT HOLDERS AND/OR OTHER PARTIES
PROVIDE THE SOFTWARE "AS IS" WITHOUT WARRANTY OF ANY KIND, EITHER
EXPRESSED OR IMPLIED, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE. THE
ENTIRE RISK AS TO THE QUALITY AND PERFORMANCE OF THE SOFTWARE IS WITH
YOU. SHOULD THE SOFTWARE PROVE DEFECTIVE, YOU ASSUME THE COST OF ALL
NECESSARY SERVICING, REPAIR, OR CORRECTION.

IN NO EVENT UNLESS REQUIRED BY APPLICABLE LAW OR AGREED TO IN WRITING
WILL ANY COPYRIGHT HOLDER, OR ANY OTHER PARTY WHO MAY MODIFY AND/OR
REDISTRIBUTE THE SOFTWARE AS PERMITTED BY THE ABOVE LICENCE, BE
LIABLE TO YOU FOR DAMAGES, INCLUDING ANY GENERAL, SPECIAL, INCIDENTAL,
OR CONSEQUENTIAL DAMAGES ARISING OUT OF THE USE OR INABILITY TO USE
THE SOFTWARE (INCLUDING BUT NOT LIMITED TO LOSS OF DATA OR DATA BEING
RENDERED INACCURATE OR LOSSES SUSTAINED BY YOU OR THIRD PARTIES OR A
FAILURE OF THE SOFTWARE TO OPERATE WITH ANY OTHER SOFTWARE), EVEN IF
SUCH HOLDER OR OTHER PARTY HAS BEEN ADVISED OF THE POSSIBILITY OF
SUCH DAMAGES.

=cut
