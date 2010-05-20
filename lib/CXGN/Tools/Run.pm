package CXGN::Tools::Run;
use strict;
use warnings;
use Carp qw/ carp confess croak /;
use POSIX qw( :sys_wait_h strftime );
use Time::HiRes qw/time/;

use IPC::Cmd ();

use Data::Dumper;

use File::Path;
use File::Temp qw( tempfile );
use File::Basename;
use File::Spec;
use Cwd;
use UNIVERSAL qw/isa/;
use File::NFSLock qw/uncache/;

use Storable qw/ nstore retrieve /;

use constant DEBUG => $ENV{CXGNTOOLSRUNDEBUG} ? 1 : 0;

# debug print function
sub dbp(@) {
  # get rid of first arg if it's one of these objects
  return 1 unless DEBUG;
  shift if( ref($_[0]) && ref($_[0]) =~ /::/ and $_[0]->isa(__PACKAGE__));
  print STDERR '# dbg '.__PACKAGE__.': ',@_;
  print STDERR "\n" unless $_[-1] =~ /\n$/;
  return 1;
}
sub dprinta(@) {
  if(DEBUG) {
    local $Data::Dumper::Indent = 0;
    print STDERR join(' ',map {ref($_) ? Dumper($_) : $_} @_)."\n";
  }
  @_
}


=head1 NAME

CXGN::Tools::Run - run an external command, either synchronously
or asynchronously (in the background).

=head1 SYNOPSIS

  ############ SYNCHRONOUS MODE #############

  #just run the program, collecting its stderr and stdout outputs

  my $run = CXGN::Tools::Run->run( 'fooprogram',
                                   -i => 'myfile.seq',
                                   -d => '/my/blast/databases/nr',
                                   -e => '1e-10',
                                 );

  print "fooprogram printed '", $run->out, "' on stdout";
  print "and it printed '", $run->err, "' on stderr";

  ############ ASYNCHRONOUS MODE ############

  #run the program in the background while your script does other
  #things, or even exits

  my $sleeper = CXGN::Tools::Run->run_async('sleep',600);
  $sleeper->is_async
    or die "But I ran this as asynchronous!";
  $sleeper->alive
    or die "Hey, it's not running!\n";

  $sleeper->wait;    #waits for the process to finish

  $sleeper->die;     #kills the process
  $sleeper->cleanup; #don't forget to clean it up, deletes tempfiles


  ############ RUNNING ON THE CLUSTER #########

  #run the job, with a temp_base directory of /data/shared/tmp
  my $cjob = CXGN::Tools::Run->run_cluster('sleep',600, {temp_base => '/data/shared/tmp'});

  print "the Torque job id for that thing is ",$cjob->job_id,"\n";

  #alive, wait, die, and all the rest work the same as for async
  $cjob->cleanup; #don't forget to clean it up, deletes tempfiles


=head1 DESCRIPTION

This class is a handy way to run an external program, either in the
foreground, in the background, or as a cluster job, connecting files
or filehandles to its STDIN, STDOUT, and STDERR.  Furthermore, the
objects of this class can be saved and restored with Storable, letting
you migrate backgrounded jobs between different instances of the
controlling program, such as when you're doing a web or SOAP interface
to a long-running computation.

One important different between using this module to run things and
using system() is that interrupt or kill signals are propagated to
child processes, so if you hit ctrl-C on your perl program, any
programs *IT* is running will also receive the SIGTERM.

If you want to see debugging output from this module, set an
environment variable CXGNTOOLSRUNDEBUG to something true, like "1", or
"you know a biologist is lying when they tell you something is
_always_ true".

=head1 CONSTRUCTORS

=cut

#make some private accessors

use Class::MethodMaker
  [ scalar => [
	       'in_file',          #holds filename or filehandle used to provide stdin
	       'out_file',         #holds filename or filehandle used to capture stdout
	       'err_file',         #holds filename or filehandle used to capture stderr
	       '_temp_base',       #holds the object-specific temp_base, if set
	       '_max_cluster_jobs',#holds the object-specific max_cluster_jobs, if set
               '_existing_temp',   #holds whether we're using someone else's tempdir
               '_told_to_die',     #holds whether this job has been told to die
	       '_working_dir',     #holds name of the process's working directory
  	       '_die_on_destroy',  #set to true if we should kill our subprocess
                                   #when this object is destroyed
	       '_pid',             #holds the pid of our background process, if any
	       '_jobid',           #holds the jobid of our cluster process, if any
	       '_jobdest',         #holds the server/queue destination
                                   #where we submitted a cluster job
	       '_error_string',    #holds our die error, if any
	       '_command',         #holds the command string that was executed
	       '_job_name',        #small name to use in tempdir names and job submission
	       '_host',            #hostname where the command ran
	       '_start_time',      #holds the time() from when we started the job
	       '_end_time',        #holds the approximate time from when the job finished
	       '_exit_status',     #holds the exit status ($?) from our job
	       '_on_completion',   #subref to be run when job completes
	       '_already_ran_completion_hooks',   #flag, set when completion hooks have been run
	       '_vmem',            #bytes of memory the process is
                                   #estimated to require
               {-default => 1},
	       '_raise_error',     #holds whether we throw errors or just store
                                   #them in _error. defaults to undef
	       '_procs_per_node',  #holds the number of processors to use for cluster
	                           #and other parallel calls
	       '_nodes',           #holds a torque-compliant nodelist, default of '1'
	                           #not used for regular and _async runs
	      ],
  ];


=head2 run

  Usage: my $slept = CXGN::Tools::Run->run('sleep',3);
         #would sleep 3 seconds, then return the object
  Desc : run the program and wait for it to finish
  Ret  : a new CXGN::Tools::Run object
  Args : executable to run (absolute or relative path, will also search $ENV{PATH}),
         argument,
         argument,
         ...,
         { in_file        => filename or filehandle to put on job's STDIN,
           out_file       => filename or filehandle to capture job's STDOUT,
           err_file       => filename or filehandle to capture job's STDERR,
           working_dir    => path of working directory to run the program,
           temp_base      => path under which to put this job's temp dir
                             defaults to the whatever the class accessor temp_base()
                             is set to,
           existing_temp  => use this existing temp dir for storing your out, err,
                             and die files.  will not automatically delete it
                             at the end of the script
           raise_error    => true if it should die on error, false otherwise.
                             default true
           on_completion  => subroutine ref to run when the job is
                             finished.  runs synchronously in the
                             parent process that spawned the job,
                             usually called from inside $job->alive() or wait().
                             passed one arg: the $job_object
         }
  Side Effects: runs the program, waiting for it to finish

=cut

sub run {
  my ($class,@args) = @_;
  my $self = bless {},$class;

  $ENV{MOD_PERL} and croak "CXGN::Tools::Run->run() not functional under mod_perl";

  my $options = $self->_pop_options( \@args );
  $self->_process_common_options( $options );

  #now start the process and die informatively if it errors
  $self->_start_time(time);

  my $curdir = cwd();
  eval {
    chdir $self->working_dir or die "Could not change directory into '".$self->working_dir."': $!";
    my $cmd = @args > 1 ? \@args : $args[0];
    CXGN::Tools::Run::Run3::run3( $cmd, $self->in_file, $self->out_file, $self->err_file, $self->tempdir );
    chdir $curdir or die "Could not cd back to parent working directory '$curdir': $!";
  }; if( $@ ) {
    $self->_error_string( $@ );
    if($self->_raise_error) {
      #write die messages to a file for later retrieval by interested
      #parties, chiefly the parent process if this is a cluster job
      $self->_write_die( $@ );
      croak $self->_format_error_message( $@ );
    }
  }
  $self->_end_time(time);
  $self->_exit_status($?); #save the exit status of what we ran

  $self->_run_completion_hooks; #< run any on_completion hooks we have

  return $self;
}

=head2 run_async

  Usage: my $sleeper = CXGN::Tools::Run->run_async('sleep',3);
  Desc : run an external command in the background
  Ret  : a new L<CXGN::Tools::Run> object, which is a handle
         for your running process
  Args : executable to run (absolute or relative path, will also search $ENV{PATH}),
         argument,
         argument,
         ...,
         { die_on_destroy => 1, #default is 0, does not matter for a synchronous run.
           in_file        => filename or filehandle,
           out_file       => filename or filehandle,
           err_file       => filename or filehandle,
           working_dir    => path of working dir to run this program
           temp_base      => path under which to but this job's temp dir,
                             defaults to the whatever the class accessor temp_base()
                             is set to,
           existing_temp  => use this existing temp dir for storing your out, err,
                             and die files.  will not automatically delete it
                             at the end of the script
           raise_error    => true if it should die on error, false otherwise.
                             default true
           on_completion  => subroutine ref to run when the job is
                             finished.  runs synchronously in the
                             parent process that spawned the job,
                             usually called from inside $job->alive() or wait()
                             passed one arg: the $job_object
         }
  Side Effects: runs the given command in the background, dies if the program
                terminated abnormally

  If you set die_on_destroy in the options hash, the backgrounded program
  will be killed whenever this object goes out of scope.

=cut

sub run_async {
  my ($class,@args) = @_;
  my $self = bless {},$class;

  $ENV{MOD_PERL} and croak "CXGN::Tools::Run->run_async() not functional under mod_perl";

  my $options = $self->_pop_options( \@args );
  $self->_process_common_options( $options );
  $self->is_async(1);

  #make sure we have a temp directory made already before we fork
  #calling tempdir() makes this directory and returns its name.
  #dbp is debug print, which only prints if $ENV{CXGNTOOLSRUNDEBUG} is set
  $self->dbp('starting background process with tempdir ',$self->tempdir);

  #make a subroutine that wraps the run3() call in order to save any
  #error messages into a file named 'died' in the process's temp dir.
  my $pid = fork;
#  $SIG{CHLD} = \&REAPER;
#  $SIG{CHLD} = 'IGNORE';
  unless($pid) {
    #CODE FOR THE BACKGROUND PROCESS THAT RUNS THIS JOB
    my $curdir = cwd();
    eval {
#       #handle setting reader/writer on IO::Pipe objects if any were passed in
      $self->in_file->reader  if isa($self->in_file,'IO::Pipe');
      $self->out_file->writer if isa($self->out_file,'IO::Pipe');
      $self->err_file->writer if isa($self->out_file,'IO::Pipe');

      chdir $self->working_dir
	or die "Could not cd to new working directory '".$self->working_dir."': $!";
#      setpgrp; #run this perl and its exec'd child as their own process group
      my $cmd = @args > 1 ? \@args : $args[0];
      CXGN::Tools::Run::Run3::run3($cmd, $self->in_file, $self->out_file, $self->err_file, $self->tempdir );
      chdir $curdir or die "Could not cd back to parent working dir '$curdir': $!";

    }; if( $@ ) {
      #write die messages to a file for later retrieval by parent process
      $self->_write_die( $@ );
    }
    #explicitly close all our filehandles, cause the hard exit doesn't do it
    foreach ($self->in_file,$self->out_file,$self->err_file) {
      if(isa($_,'IO::Handle')) {
#	warn "closing $_\n";
	close $_;
      }
    }
    POSIX::_exit(0); #call a HARD exit to avoid running any weird END blocks
                     #or DESTROYs from our parent thread
  }
  #CODE FOR THE PARENT
  $self->_pid($pid);

  $self->_die_if_error;              #check if it's died
  return $self;
}

=head2 run_cluster

  Usage: my $sleeper = CXGN::Tools::Run->run_cluster('sleep',30);
  Desc : run a command on a cluster using the 'qsub' command
  Ret  : a new L<CXGN::Tools::Run> object, which is a handle
         for your running cluster job
  Args : executable to run (absolute or relative path, will also search $ENV{PATH}),
         argument,
         argument,
         ...,
         { die_on_destroy => 1, #default is 0
           in_file        => do not use, not yet supported for cluster jobs
           out_file       => filename, defaults to a new one created internally,
           err_file       => filename, defaults to a new one created internally,
           working_dir    => path of working dir to run this program
           temp_base      => path under which to put this job's temp dir
                             defaults to the whatever the class accessor temp_base()
                             is set to,
           on_completion  => subroutine ref to run when the job is
                             finished.  runs synchronously in the
                             parent process that spawned the job,
                             usually called from inside $job->alive()
                             passed one arg: the $job_object
           existing_temp  => use this existing temp dir for storing your out, err,
                             and die files.  will not automatically delete it
                             at the end of the script
           raise_error    => true if it should die on error, false otherwise.
                             default true,
           nodes          => torque-compatible node list to use for running this job.  default is '1',
           procs_per_node => number of processes this job will use on each node.  default 1,
           vmem           => estimate of total virtual memory (RAM) used by the process, in megabytes,
           queue          => torque-compatible job queue specification string, e.g. 'batch@solanine',
                             if running in a web environment, defaults to the value of the
                             'web_cluster_queue' conf key, otherwise, defaults to blank, which will
                             use the default queue that the 'qsub' command is configured to use.
         }
  Side Effects: runs the given command in the background, dies if the program
                terminated abnormally

  If you set die_on_destroy in the options hash, the job will be killed with `qdel`
  if this object goes out of scope.

=cut

sub run_cluster {
  my ($class,@args) = @_;

  my $self = bless {},$class;

  my $options = $self->_pop_options( \@args );
  $self->_process_common_options( $options );

  return $self->_run_cluster( \@args, $options );
}

sub _run_cluster {
    my ( $self, $cmd, $options ) = @_;

    $self->is_cluster(1);

    $self->_command( $cmd ); #< store the command for use in error messages

  # set our job destination from configuration if running under the website
  if( defined $options->{queue} ) {
      $self->_jobdest($options->{queue});
  }
  # TODO: change all SGN code to pass in queue =>, then remove this!
  elsif( defined $ENV{PROJECT_NAME} && $ENV{PROJECT_NAME} eq 'SGN' ) {
      require SGN::Context;
      if( my $q = SGN::Context->new->get_conf('web_cluster_queue') ) {
	  $self->_jobdest( $q );
      }
  }

  #check that qsub is actually in the path
  IPC::Cmd::can_run('qsub')
	or croak "qsub command not in path, cannot submit jobs to the cluster.  "
	        ."Maybe you need to install the torque package?";

  #check that our out_file, err_file, and in_file are accessible from the cluster nodes
  sub cluster_accessible {
    my $path = shift;
#    warn "relpath $path\n";
    $path = File::Spec->rel2abs("$path");
#    warn "abspath $path\n";
    return 1 if $path =~ m!(/net/[^/]+)?(/data/(shared|prod|trunk)|/(home|crypt))!;
    return 0;
  }

  my $tempdir = $self->tempdir;
  $self->in_file
      and croak "in_file not supported by run_cluster";
  foreach my $acc ('out_file','err_file') {
      my $file = $self->$acc;
      $file = $self->$acc("$file"); #< stringify the argument

      croak "tempdir ".$self->tempdir." is not on /data/shared or /data/prod, but needs to be for cluster jobs.  Do you need to set a different temp_base?\n"
	unless cluster_accessible($tempdir);

      croak "filehandle or non-stringifying out_file, err_file, or in_file not supported by run_cluster"
	  if $file =~ /^([\w:]+=)?[A-Z]+\(0x[\da-f]+\)$/;
      #print "file was $file\n";

    unless(cluster_accessible($file)) {
      if(index($file,$tempdir) != -1) {
		croak "tempdir ".$self->tempdir." is not on /data/shared or /data/prod, but needs to be for cluster jobs.  Do you need to set a different temp_base?\n";
      } else {
		croak "'$file' must be in a subdirectory of /data/shared or /data/prod in order to be accessible to all cluster nodes";
      }
    }
  }

  #check that our working directory, if set, is accessible from the cluster nodes
  if($self->_working_dir_isset) {
    cluster_accessible($self->_working_dir)
      or croak "working directory '".$self->_working_dir."' is not a subdirectory of /data/shared or /data/prod, but should be in order to be accessible to the cluster nodes";
  }


  # if the cluster head node is currently is running more than
  # max_cluster_jobs jobs, don't overload it, block until the number
  # of jobs goes down.  prints a warning the first time in the run
  # that this happens
  $self->_wait_for_overloaded_cluster;

  ###submit the job with qsub in the form of a bash script that contains a perl script
  #we do this so we can use CXGN::Tools::Run to write
  my $working_dir = $self->_working_dir_isset ? "working_dir => '".$self->_working_dir."'," : '';
  my $cmd_string = do {
      local $Data::Dumper::Terse  = 1;
      local $Data::Dumper::Indent = 0;
      join ', ', map Dumper( "$_" ), @$cmd;
  };
  my $outfile = $self->out_file;
  my $errfile = $self->err_file;

  $cmd_string = <<'EOSCRIPT'
#!/usr/bin/env perl

  # take PBS_O_* environment variables as our own, overriding local
  # node settings
  %ENV = ( %ENV,
	   map {
	       my $orig = $_;
	       if(s/PBS_O_//) {
		   $_ => $ENV{$orig}
	       } else {
		   ()
	       }
	   }
	   keys %ENV
          );

EOSCRIPT
  .<<EOSCRIPT;
  CXGN::Tools::Run->run($cmd_string,
                        { out_file => '$outfile',
                          err_file => '$errfile',
                          existing_temp => '$tempdir',
                          $working_dir
                        });

EOSCRIPT

  dbp "running cmd_string:\n$cmd_string\n";

  # also, include a copy of this very module!
  $cmd_string .= $self->_file_contents( __FILE__ );
  # disguise the ending EOF so that it passes through the file inclusion

  #$self->dbp("cluster running command '$cmd_string'");
  my $cmd_temp_file = File::Temp->new( File::Spec->catfile( File::Spec->tmpdir, 'cxgn-tools-run-cmd-temp-XXXXXX' ) );
  $cmd_temp_file->print( $cmd_string );
  $cmd_temp_file->close;

  my $retry_count;
  my $qsub_retry_limit = 3; #< try 3 times to submit the job
  my $submit_success;
  until( ($submit_success = $self->_submit_cluster_job( $cmd_temp_file )) || ++$retry_count > $qsub_retry_limit ) {
      sleep 1;
      warn "CXGN::Tools::Run retrying cluster job submission.\n";
  }
  $submit_success or die "CXGN::Tools::Run: failed to submit cluster job, after $retry_count tries\n";

  $self->_die_if_error;

  return $self;
}

sub _submit_cluster_job {
    my ($self, $cmd_temp_file) = @_;

    my %resources = (
        ppn => $self->_procs_per_node || undef,
        nodes => $self->_nodes        || 1,
        vmem  => $self->_vmem         || undef,
       );
    my $resource_str = $self->_make_torque_resource_string(\%resources);

    #note that you can use a reference to a string as a filehandle, which is done here:
    my $qsub_cmd = join( ' ',
                         #my $qsub = CXGN::Tools::Run->run(
                         dprinta( "qsub",
                                  '-V',
                                  -r => 'n', #< not rerunnable, cause we'll notice it died
                                  -o => '/dev/null',
                                  -e => $self->err_file,
                                  -N => $self->_job_name,
                                  ( $self->_working_dir_isset ? (-d => $self->working_dir)
                                        : ()
                                       ),
                                  ( $self->_jobdest_isset ? (-q => $self->_jobdest)
                                        : ()
                                       ),
                                  -l => $resource_str,
                                  $cmd_temp_file,
                                  #{ in_file  => \$cmd_string,
                                  #  out_file => \$jobid,
                                  #}
                                 )
                        );
    #die "running '$qsub_cmd'";
    my $jobid = `$qsub_cmd 2>&1`; #< string to hold the job ID of this job submission

    # test hook for testing a qsub failure, makes the test fail the first time
    if( $ENV{CXGN_TOOLS_RUN_FORCE_QSUB_FAILURE} ) {
        $jobid = $ENV{CXGN_TOOLS_RUN_FORCE_QSUB_FAILURE};
        delete $ENV{CXGN_TOOLS_RUN_FORCE_QSUB_FAILURE};
    }

    $self->_flush_qstat_cache;  #< force a qstat update

    #check that we got a sane job id
    chomp $jobid;
    unless( $jobid =~ /^\d+(\.[a-zA-Z0-9-]+)+$/ ) {
        warn "CXGN::Tools::Run error running `qsub`: $jobid\n";
        return;
    }

    dbp( "got jobid $jobid" );


    $self->_jobid($jobid);      #< remember our job id

    return 1;
}

sub _make_torque_resource_string {
    my ($self, $r) = @_;
    my %r = %$r;

    # tweak nodes=
    my $ppn = delete $r{ppn};
    $r{nodes} .= ":ppn=$ppn" if $ppn;

    # tweak vmem=
    $r{vmem}  .= 'm' if defined $r{vmem};

    my $s = join ',',           #< joined by commas
        map {"$_=$r{$_}"}       #< print it as type=value
            grep defined $r{$_}, #< don't print any that are undef
                sort            #< in stable sorted order
                    keys %r;    #< for each resource type

    return $s;
}



=head2 run_cluster_perl

  Usage: my $job = CXGN::Tools::Run->run_cluster_perl({ args => see below })

  Desc : Like run_cluster, but calls a perl class method on a cluster
         node with the given args.  The method args can be anything
         that Storable can serialize.  The actual job launched on the
         node is something like:
            perl -M$class -e '$class->$method_name(@args)'

         where the @args are exactly what you pass in method_args.

  Args : {  method        => [ Class::Name => 'method_to_run' ],
            args          => arrayref of the method's arguments (can
                             be objects, datastructures, whatever),

            (optional)
            run_opts      => hashref of CXGN::Tools::Run options (see
                             run_cluster() above),
            load_packages => arrayref of perl packages to
                             require before deserializing the arguments,
            perl          => string or arrayref specifying how to invoke
                             perl on the remote node, defaults to
                             [ '/usr/bin/env', 'perl' ]
         }
  Ret  : a job object, same as run_cluster

=cut

sub run_cluster_perl {
  my ( $class, $args ) = @_;
  my ( $perl, $method_args, $run_args, $packages ) =
      @{$args}{qw{ perl args run_opts load_packages}};

  my ($method_class, $method_name) = @{ $args->{method} };

  $method_args ||= [];
  $run_args ||= {};
  $perl ||= [qw[ /usr/bin/env perl ]];
  my @perl = ref $perl ? @$perl : ($perl);

  my $self = bless {},$class;
  $self->_job_name( $method_name );
  $self->_process_common_options( $run_args );

  $packages ||= [];
  $packages = [$packages] unless ref $packages;
  $packages = join '', map "require $_; ", @$packages;

  if ( @$method_args ) {
      my $args_file = File::Spec->catfile( $self->tempdir, 'args.dat' );
      nstore( $method_args => $args_file ) or croak "run_cluster_perl: $! serializing args to '$args_file'";
      return $self->_run_cluster(
          [ @perl,
            '-MStorable=retrieve',
            '-M'.$class,
            -e => $packages.$method_class.'->'.$method_name.'(@{retrieve("'.$args_file.'")})',
          ],
          $run_args,
         );
    } else {
        return $self->_run_cluster(
            [ @perl,
              '-MStorable=retrieve',
              '-M'.$class,
              -e => $packages.$method_class.'->'.$method_name.'()',
            ],
            $run_args,
           );
   }
}

sub _run_cluster_perl_test { print 'a string for use by the test suite ('.join(',',@_).')' }


# if the cluster head node is currently is running more than
# max_cluster_jobs jobs, don't overload it, block until the number
# of jobs goes down.  prints a warning the first time in the run
# that this happens
{ my $already_warned;
  sub _wait_for_overloaded_cluster {
      my $self = shift;
      if ( $self->_cluster_queue_jobs_count >= $self->_max_cluster_jobs ) {

	  # warn the first time the cluster-full condition is encountered
	  unless( $already_warned++ ) {
	      carp __PACKAGE__.": WARNING: cluster queue contains more than "
		  .$self->_max_cluster_jobs
		      ." (max_cluster_jobs) jobs, throttling job submissions\n";
	  }

	  sleep int rand 120 while $self->_cluster_queue_jobs_count >= $self->_max_cluster_jobs;
      }
  }
}

sub _pop_options {
    my ( $self, $args ) = @_;

    #make sure all of our args are defined
    defined || croak "undefined argument passed to run method" foreach @$args;

    my $options = ref($args->[-1]) eq 'HASH' ?  pop( @$args ) : {};

    #store our command array for later use in error messages and such
    $self->_command($args);

    unless( $self->_job_name ) {
        my ($executable) = $self->_command->[0] =~ /^([^'\s]+)/;
        $executable ||= '';
        if($executable) {
            $executable = basename($executable);
        }
        $self->_job_name($executable)
    }

    return $options;
}

#process the options hash and set the correct parameters in our object
#use for input and output
sub _process_common_options {
  my ( $self, $options ) = @_;

  my @allowed_options = qw(
			   in_file
			   out_file
			   err_file
			   working_dir
			   temp_base
			   max_cluster_jobs
			   existing_temp
			   raise_error
			   die_on_destroy
			   procs_per_node
                           on_completion
			   nodes
			   vmem
			   queue
			  );
  foreach my $optname (keys %$options) {
    grep {$optname eq $_} @allowed_options
      or croak "'$optname' is not a valid option for run_*() methods\n";
  }

  #given a filehandle or filename, absolutify it if it is a filename
  sub abs_if_filename($) {
    my $name = shift
        or return;
    ref($name) ? $name : File::Spec->rel2abs($name);
  }

  #set our temp_base, if given
  $self->_temp_base( $options->{temp_base} ) if defined $options->{temp_base};

  #if an existing temp dir has been passed, verify that it exists, and
  #use it
  if(defined $options->{existing_temp}) {
    $self->{tempdir} = $options->{existing_temp};
    -d $self->{tempdir} or croak "existing_temp '$options->{existing_temp}' does not exist";
    -w $self->{tempdir} or croak "existing_temp '$options->{existing_temp}' is not writable";
    $self->_existing_temp(1);
  }

  #figure out where to put the files for the stdin and stderr
  #outputs of the program.  Make sure to use absolute file names
  #in case the working dir gets changed
  $self->out_file( abs_if_filename( $options->{out_file}
				    || File::Spec->catfile($self->tempdir, 'out')
				  )
		 );
  $self->err_file( abs_if_filename( $options->{err_file}
				    || File::Spec->catfile($self->tempdir, 'err')
				  )
		 );
  $self->in_file( abs_if_filename $options->{in_file} );

  $self->working_dir( $options->{working_dir} );

  dbp "Got dirs and files ",map {$_||=''; "'$_' "} $self->out_file, $self->err_file, $self->in_file, $self->working_dir;

  $self->_die_on_destroy(1) if $options->{die_on_destroy};
  $self->_raise_error(0) if defined($options->{raise_error}) && !$options->{raise_error};

  $self->_procs_per_node($options->{procs_per_node}) if defined $options->{procs_per_node};
  $self->_nodes($options->{nodes}) if defined $options->{nodes};
  $self->_vmem($options->{vmem}) if defined $options->{vmem};

  $self->_max_cluster_jobs( $options->{max_cluster_jobs} || 2000 );

  if( defined $options->{on_completion} ) {
      my $c = $options->{on_completion};
      $c = [$c] unless ref $c eq 'ARRAY';
      foreach (@$c) {
          ref eq 'CODE'
              or croak 'on_completion hooks must each be a CODE reference';
      }
      $self->_on_completion( $c );
  }

  # set is_cluster and is_async defaults
  $self->is_cluster(0);
  $self->is_async(0);

  return $options;
}

# NOTE: temp_base class method is deprecated, do not use in new code.
#  pass temp_base to each Run invocation instead
# =head2 temp_base

#   Usage: CXGN::Tools::Run->temp_base('/data/local/temp');

#   Desc : class method to get/set the base directory where these
#          objects put their tempfiles.  This defaults to the value of
#          File::Spec->tmpdir (which is usually '/tmp')

#   Ret  : directory name of place to put temp files
#   Args : (optional) name of new place to put temp files

# =cut

# return the base path where CXGN::Tools::Run classes
# should stick their temp dirs, indexes, whatever
{ my %tb = ( __PACKAGE__ , File::Spec->tmpdir );
  sub temp_base {
      my ( $class, $val ) = @_;
      $tb{$class} = $val if @_ > 1;
      return $tb{$class};
  }
}

=head1 OBJECT METHODS

=head2 tempdir

  Usage: my $dir = $job->tempdir;
  Desc : get this object's temporary directory
  Ret  : the name of a unique temp directory used for
         storing the output of this job
  Args : none
  Side Effects: creates a temp directory if one has not yet
                been created

=cut

#object accessor that returns a path to an exclusive
#temp dir for that object.  Does not actually
#create a temp directory until called.
my @CHARS = (qw/ A B C D E F G H I J K L M N O P Q R S T U V W X Y Z
	         a b c d e f g h i j k l m n o p q r s t u v w x y z
	         0 1 2 3 4 5 6 7 8 9 _
	     /); #< list of characters that can be used in tempfile names

sub tempdir {
  my ($self) = @_;

  #return our current temp dir if we have one
  return $self->{tempdir} if $self->{tempdir};

  #otherwise make a new temp dir

  #TODO: do tempdir stem-and-leafing
  #number of dirs in one dir = $#CHARS ^ $numchars
  #number of possible combinations = $#CHARS ^ ($numchars+$numlevels)
  my $numlevels = 5;
  my $numchars  = 2;
  my $username = getpwuid $>;
  my $temp_stem = File::Spec->catdir( ( $self->_temp_base() || __PACKAGE__->temp_base() ),
				      $username.'-cxgn-tools-run-tempfiles',
				      ( map {$CHARS[int rand $#CHARS].$CHARS[int rand $#CHARS]} 1..$numlevels ),
				    );
  mkpath($temp_stem);
  -d $temp_stem or die "could not make temp stem '$temp_stem'\n";

  my $job_name = $self->_job_name || 'cxgn-tools-run';

  my $newtemp = File::Temp::tempdir($job_name.'-XXXXXX',
 				    DIR     => $temp_stem,
 				    CLEANUP => 0, #don't delete our kids' tempfiles
 				   );
  -d $newtemp and -w $newtemp
    or die __PACKAGE__.": Could not make temp dir in ".__PACKAGE__->temp_base().": $!";

  $self->{tempdir} = $newtemp;
  dbp "Made new temp dir $newtemp\n";

  return $self->{tempdir};
}


#returns the name of the file to use for recording the die message from background jobs
sub _diefile_name {
  my $self = shift;
  return File::Spec->catfile( $self->tempdir, 'died');
}

#write a properly formatted error message to our diefile
sub _write_die {
  my ($self,$error) = @_;
  open my $diefile, ">".$self->_diefile_name
    or die "Could not open file ".$self->_diefile_name.": $error: $!";
  print $diefile $self->_format_error_message($error);
  return 1;
}

# croak()s if our subprocess terminated abnormally
sub _die_if_error {
  my $self = shift;
  if( ($self->is_async || $self->is_cluster)
      && $self->_diefile_exists) {
    my $error_string = $self->_file_contents( $self->_diefile_name );
    if( $self->is_cluster ) {
	# if it's a cluster job, look for warnings from the resource
	# manager in the error file and include those in the error output
	my $pbs_warnings = '';
	if( -f $self->err_file ) {
	    eval {
		open my $e, $self->err_file or die "WARNING: $! opening err file ".$self->err_file;
		while( <$e> ) {
		    next unless m|^\=\>\> PBS:|;
		    $pbs_warnings .= $_;
		}
		$pbs_warnings = __PACKAGE__.": resource manager output:\n$pbs_warnings" if $pbs_warnings;
	    };
	    $pbs_warnings .= $@ if $@;
	}
	# and also prepend the cluster job ID to aid troubleshooting
        my $jobid = $self->job_id;
	$error_string =  __PACKAGE__.": cluster job id: $jobid\n"
	               . $pbs_warnings
		       . $error_string
                       . '==== '.__PACKAGE__.' running qstat -f on this job ==========='
                       . `qstat -f '$jobid'`
                       . '==== '.__PACKAGE__.' end qstat output ======================='
    }
    #kill our child process's whole group if it's still running for some reason
    kill SIGKILL => -($self->pid) if $self->is_async;
    $self->_error_string($error_string);
    if($self->_raise_error && !($self->_told_to_die && $error_string =~ /Got signal SIG(INT|QUIT|TERM)/)) {
      croak($error_string || 'subprocess died, but returned no error string');
    }
  }
}

# runs the completion hook(s) if present
sub _run_completion_hooks {
    my $self = shift;

    $self->_die_if_error; #if our child died, we should die too, not run the completion hooks

    dbp 'running job completion hook';

    #skip if we have no completion hooks or we have already run them
    return unless $self->_on_completion && ! $self->_already_ran_completion_hooks;

    #run the hooks
    $_->($self,@_) for @{ $self->_on_completion };

    #set flag saying we have run them
    $self->_already_ran_completion_hooks(1);
}

sub _diefile_exists {
  my ($self) = @_;
  unless($self->is_cluster) {
    return -e $self->_diefile_name;
  } else {
    #have to do the opendir dance instead of caching, because NFS caches the stats
    opendir my $tempdir, $self->tempdir;
    while(my $f = readdir $tempdir) {
      #dbp "is '$f' my diefile?\n";
      return 1 if $f eq 'died';
    }
    return 0;
  }
}

sub _file_contents {
  my ($self,$file) = @_;
  uncache($file) if $self->is_cluster;
  local $/;
  open my $f, $file or confess "$! reading $file";
  return scalar <$f>;
}

#takes an error text string, adds some informative context to it,
#then returns the new string
sub _format_error_message {
  my $self = shift;
  my $error = shift || 'no error message';
  $error =~ s/[\.,\s]*$//; #chop off any ending punctuation or whitespace
  my $of = $self->out_file;
  my $ef = $self->err_file;
  my @out_tail = do {
    unless(ref $of) {
      "last few lines of stdout:\n",`tail -20 $of 2>&1`
    } else {
      ("(no stdout captured)")
    }
  };
  my @err_tail = do {
    unless(ref $ef) {
      "last few lines of stderr:\n",`tail -20 $ef 2>&1`
    } else {
      ("(no stderr captured)")
    }
  };
  return join '', map {chomp; __PACKAGE__.": $_\n"} (
      "start time: ".( $self->start_time ? strftime('%Y-%m-%d %H:%M:%S %Z', localtime($self->start_time) ) : 'NOT RECORDED' ),
      "error time: ".strftime('%Y-%m-%d %H:%M:%S %Z',localtime),
      "command failed: '" . join(' ',@{$self->_command}) . "'",
      $error,
      @out_tail,
      @err_tail,
  );
}


=head2 out_file

  Usage: my $file = $run->out_file;
  Desc : get the filename or filehandle that received the
         the stdout of the thing you just ran
  Ret  : a filename, or a filehandle if you passed in a filehandle
         with the out_file option to run()
  Args : none

=cut

#
#out_file() is generated by Class::MethodMaker above
#

=head2 out

  Usage: print "the program said: ".$run->out."\n";
  Desc : get the STDOUT output from the program as a string
         Be careful, this is in a tempfile originally, and if it's
         got a lot of stuff in it you'll blow your memory.
         Consider using out_file() instead.
  Ret  : string containing the output of the program, or undef
         if you set our out_file to a filehandle
  Args : none

=cut

sub out {
  my ($self) = @_;
  unless(ref($self->out_file)) {
    $self->dbp("Outfile is ",$self->out_file,"\n");
    return $self->_file_contents($self->out_file);
  }
  return undef;
}


=head2 err_file

  Usage: my $err_filename = $run->err_file
  Desc : get the filename or filehandle that received
         the STDERR output
  Ret  : a filename, or a filehandle if you passed in a filehandle
         with the err_file option to run()
  Args : none

=cut

#
#err_file() is generated by Class::MethodMaker above
#

=head2 err

  Usage: print "the program errored with ".$run->err."\n";
  Desc : get the STDERR output from the program as a string
         Be careful, this is in a tempfile originally, and if it's
         too big you'll run out of memory.
         Consider using err_file() instead.
  Ret  : string containing the program's STDERR output, or undef
         if you set your err_file to a filehandle
  Args : none

=cut

sub err {
  my ($self) = @_;
  unless(ref($self->err_file)) {
    return $self->_file_contents( $self->err_file );
  }
  return undef;
}

=head2 error_string

  Usage: my $err = $runner->error_string;
  Desc : get the string contents of the error
         we last die()ed with, if any.
         You would mostly want to check this
         if you did a run() with raise_error
         set to false
  Ret  : undef if there has been no error,
         or a string if there has been.
  Args : none
  Side Effects: none

=cut

sub error_string {
  shift->_error_string;
}

=head2 in_file

  Usage: my $infile_name = $run->in_file;
  Desc : get the filename or filehandle used for the process's stdin
  Ret  : whatever you passed in the in_file option to run(), if anything.
         So that would be either a filename or a filehandle.
  Args : none

=cut

#
#in_file() is defined by Class::MethodMaker above
#

=head2 working_dir

  Usage: my $dir = $run->working_dir
  Desc : get/set the full pathname (string) of the process's working dir.
         Defaults to the parent process's working directory.
  Ret  : the current or new value of the working directory
  Args : (optional) new path for the working directory of this process
  Side Effects: gets/sets the working directory where the process is/will be
                running
  Note: attempting to set the working directory on a process that is currently
        running will throw an error

=cut

sub working_dir {
  my ($self,$newdir) = @_;

  if($newdir) {
    -d $newdir or croak "'$newdir' is not a directory";
    $self->alive and croak "cannot set the working dir on a running process";
    $self->_working_dir($newdir);
  }

  $self->_working_dir(File::Spec->curdir) unless $self->_working_dir;
  return $self->_working_dir;
}

=head2 is_async

  Usage: print "It was asynchronous" if $runner->is_async;
  Desc : tell whether this run was asynchronous (run_async or run_cluster)
  Ret  : 1 if the run was asynchronous, 0 if not
  Args : none

=cut

sub is_async {
    my $self = shift;
    $self->{is_async} = shift if @_;
    return $self->{is_async};
}

=head2 is_cluster

  Usage: print "It's a cluster job" if $runner->is_cluster;
  Desc : tell whether this run was done with a job submitted to the cluster
  Ret  : 1 if it's a cluster job, 0 if not
  Args : none

=cut

sub is_cluster {
    my $self = shift;
    $self->{is_cluster} = shift if @_;
    return $self->{is_cluster};
}

=head2 alive

  Usage: print "It's still there" if $runner->alive;
  Desc : check whether our background process is still alive
  Ret  : false if it's not still running or was synchronous,
         true if it's async or cluster and is still running.
         Additionally, if it's a cluster job, the true value
         returned will be either 'ending', 'running' or 'queued'.
  Args : none
  Side Effects: dies if our background process terminated abnormally

=cut

sub alive {
  my ($self) = @_;

  $self->_die_if_error; #if our child died, we should die too

  if( $self->is_async) {
    #use a kill with signal zero to see if that pid is still running
    $self->_reap;
    if( kill 0 => $self->pid ) {
      system("pstree -p | egrep '$$|".$self->pid."'") if DEBUG;
      dbp 'background job '.$self->pid." is alive.\n";
      return 1;
    } else {
      system("pstree -p | egrep '$$|".$self->pid."'") if DEBUG;
      dbp 'background job ',$self->pid," is dead.\n";
      $self->_run_completion_hooks unless $self->_told_to_die;
      return;
    }
  } elsif( $self->is_cluster ) {
    #use qstat to see if the job is still alive
    my %m = qw| e ending r running q queued |;
    my $state = $m{ $self->_qstat->{'job_state'} || '' };
    $self->_run_completion_hooks unless $state || $self->_told_to_die;
    return $state;
  }
  $self->_die_if_error; #if our child died, we should die too
  return;
}

sub _cluster_queue_jobs_count {
    my $cnt = scalar keys %{ shift->_global_qstat || {} };
    #print "jobs count: $cnt\n";
    return $cnt;
}

sub _qstat {
    my ($self) = @_;
    my $jobs = $self->_global_qstat;
    return $jobs->{$self->_jobid} || {};
}

#keep a cached copy of the qstat results, updated at most every MIN_QSTAT_WAIT
#seconds, to avoid pestering the server too much

use constant MIN_QSTAT_WAIT => 3;
{
    my $jobstate;
    my $last_qstat_time;
    sub _flush_qstat_cache {
	$last_qstat_time = 0;
    }
    sub _global_qstat {
	my ($self,%opt) = @_;

	#return our cached job state if it has been updated recently
	unless( defined($last_qstat_time) && (time()-$last_qstat_time) <= MIN_QSTAT_WAIT ) {
	    #otherwise, update it and return it
	    $jobstate = {};
	    my $servername = $self->_jobdest_isset ? $self->_jobdest : '';
	    $servername =~ s/^[^@]+//;
	    #    warn "using server name $servername\n";
	    open my $qstat, "qstat -f $servername 2>&1 |";
	    my $current_jobid;
	    while (my $qs = <$qstat>) {
		#      dbp "got qstat record:\n$qs";
		if ($qs =~ /\s*Job\s+Id\s*:\s*(\S+)/i) {
		    $current_jobid = $1;
		} elsif ( my ($key,$val) = $qs =~ /^\s*([^=\s]+)\s*=\s*(\S+)/ ) {
		    next if $key =~ /[=:]/;
		    $jobstate->{$current_jobid}->{lc($key)} = lc $val;
		} elsif ( $qs =~ /qstat: (.+)/ ) { #< probably some kind of error
		    if( $opt{no_recurse} ) {
			warn $qs;
			warn $_ while <$qstat>;
			return {};
		    } else {
			sleep 3;	#< wait a bit and try a second time
			return $self->_global_qstat( no_recurse => 1 );
		    }
		}
	    }
	    $last_qstat_time = time();
	    #      use Data::Dumper;
	    #      warn "qstat hash is now: ".Dumper($jobstate);
	}
	return $jobstate;
    }
}

=head2 wait

  Usage: my $status = $job->wait;
  Desc : this subroutine blocks until our job finishes
         of course, if the job was run synchronously,
         this will return immediately
  Ret  : the exit status ($?) of the job
  Args : none

=cut

sub wait {
  my ($self) = @_;
  $self->_die_if_error;
  if($self->is_async && $self->alive) { #< for backgrounded jobs
    $self->_reap(1); #blocking wait
  } elsif($self->is_cluster && $self->alive) {#< for cluster jobs
    #spin wait for the cluster job to finish
    do { sleep 2; $self->_die_if_error; } while $self->alive;
  }
  die 'sanity check failed, process is still alive' if $self->alive;
  $self->_die_if_error;
  return $self->exit_status;
}

=head2 die

  Usage: die "Could not kill job!" unless $runner->die;
  Desc : Reliably try to kill the process, if it is being run
         in the background.  The following signals are sent to
         the process at one second intervals until the process dies:
         HUP, QUIT, INT, KILL.
  Ret  : 1 if the process no longer exists once die has completed, 0 otherwise.
         Will always return 1 if this process was not run in the background.
  Args : none
  Side Effects: tries really hard to kill our background process

=cut

sub die {
  my ($self) = @_;
  $self->_told_to_die(1);
  if($self->is_async) {
    $self->_reap; #reap if necessary
    my @signal_sequence = qw/SIGQUIT SIGINT SIGTERM SIGKILL/;
    foreach my $signal (@signal_sequence) {
      if(kill $signal => $self->pid) {
	dbp "DIE(".$self->pid.") OK with signal $signal";
      } else {
	dbp "DIE(".$self->pid.") failed with signal $signal";
      }
      sleep 1;
      $self->_reap; #reap if necessary
      last unless $self->alive;
    }
    $self->_reap; #reap if necessary
    return $self->alive ? 0 : 1;
  } elsif( $self->is_cluster ) {
    $self->_flush_qstat_cache; #< force a qstat update
    dbp "trying first run qdel ",$self->_jobid,"\n";
    if($self->alive) {
	my $jobid = $self->_jobid;
	my $qdel = `qdel $jobid 2>&1`;
	if ($self->alive) {
	    sleep 3;		#wait a bit longer
	    if ($self->alive) {	#try the del again
		dbp "trying again qdel ",$self->_jobid,"\n";
		$qdel = `qdel $jobid 2>&1`;
		sleep 7;	#wait again for it to take effect
		if ($self->alive) {
		    die("Unable to kill cluster job ".$self->_jobid.", qdel output: $qdel" );
		}
	    }
	}
    }
  }
  return 1;
}

=head2 pid

  Usage: my $pid = $runner->pid
  Ret  : the PID of our background process, or
         undef if this command was not run asynchronously
  Args : none
  Side Effects: none

=cut

sub pid { #just a read-only wrapper for _pid setter/getter
  shift->_pid;
}

=head2 job_id

  Usage: my $jobid = $runner->job_id;
  Ret  : the job ID of our cluster job if this was a cluster job, undef otherwise
  Args : none
  Side Effects: none

=cut

sub job_id {
  shift->_jobid;
}


=head2 host

  Usage: my $host = $runner->host
  Desc : get the hostname of the host that ran or is running this job
  Ret  : hostname, or undef if the job has not been run (yet)
  Args : none

=cut

sub host {
  my $self = shift;
  return $self->_host if $self->_host_isset;
  confess 'should have a hostname by now' unless $self->is_async || $self->is_cluster;
  $self->_read_status_file;
  return $self->_host;

}

=head2 start_time

  Usage: my $start = $runner->start_time;
  Desc : get the number returned by time() for when this process
         was started
  Ret  : result of time() for just before the process was started
  Args : none

=cut

sub start_time {
  my $self = shift;
  return $self->_start_time if $self->_start_time_isset;
  confess 'should have a start time by now' unless $self->is_async || $self->is_cluster;
  $self->_read_status_file;
  return $self->_start_time;
}

=head2 end_time

  Usage: my $elapsed = $runner->end_time - $runner->start_time;
  Desc : get the number returned by time() for when this process was
         first noticed to have stopped.
  Ret  : time()-type number
  Args : none

  This end time is approximate, since I haven't yet figured out a way
  to get an asynchronous notification when a process finishes that isn't
  necessarily a child of this process.  So as a kludge, pretty much every
  method you call on this object checks whether the process has finished and
  sets the end time if it has.

=cut

sub end_time {
  my $self = shift;
  if($self->is_async) {
    $self->_reap;
    return undef if $self->alive;
    $self->_read_status_file;
  }
  return $self->_end_time;
}
sub _read_status_file {
  my $self = shift;

  return unless $self->is_async || $self->is_cluster; #this only applies to async and cluster jobs
  return if $self->_end_time_isset;

  my $statname = File::Spec->catfile( $self->tempdir, 'status');
  uncache($statname) if $self->is_cluster;
  dbp "attempting to open status file $statname\n";
  open my $statfile, $statname
    or return;
  my ($host,$start,$end,$ret);
  while(<$statfile>) {
    dbp $_;
    if( /^start:(\d+)/ ) {
      $start = $1;
    } elsif( /^end:(\d+)/) {
      $end = $1;
    } elsif( /^ret:(\d+)/) {
      $ret = $1;
    } elsif( /^host:(\S+)/) {
      $host = $1;
    } else {
      dbp "no match: $_";
    }
  }
  $self->_start_time($start);
  $self->_host($host);
  $self->_end_time($end) if defined $end;
  $self->_exit_status($ret) if defined $ret;
}

=head2 exit_status

  Usage: my $status = $runner->exit_status
  Desc : get the exit status of the thing that just ran
  Ret  : undef if the thing hasn't finished yet, otherwise,
         returns the exit status ($?) of the program.
         For how to handle this value, see perlvar.
  Args : none

=cut

sub exit_status {
  my $self = shift;
  return $self->_exit_status if $self->_exit_status_isset;
  $self->_read_status_file;
  return $self->_exit_status;
}

=head2 cleanup

  Usage: $runner->cleanup;
  Desc : delete temp storage associated with this object, if any
  Ret  : 1 on success, dies on failure
  Args : none
  Side Effects: deletes any temporary files or directories associated
                with this object


  Cleanup is done automatically for run() jobs, but not run_async()
  or run_cluster() jobs.

=cut

sub cleanup {
  my ($self) = @_;
  $self->_reap if $self->is_async;

  # assemble list of stem directories to try to delete (if they are
  # not empty)
  # WARNING THIS WORKS ONLY ON UNIX-STYLE PATHS RIGHT NOW

  my @delete_dirs;
  if( my $t = $self->{tempdir} ) {
    $t =~ s!/$!!; #< remove any trailing slash
    while(  $t =~ s!/[^/]+$!! && $t !~ /cxgn-tools-run-tempfiles$/ ) {
      push @delete_dirs, $t;
    }
  }

  if( $self->{tempdir} && -d $self->{tempdir} ) {
    rmtree($self->{tempdir}, DEBUG ? 1 : 0);
  }

  rmdir $_ foreach @delete_dirs;

  return 1;
}

=head2 do_not_cleanup

  Usage: $runner->do_not_cleanup;
  Desc : get/set flag that disables automatic cleaning up of this
         object's tempfiles when it goes out of scope
  Args : true to set, false to unset
  Ret  : current value of flag

=cut

sub do_not_cleanup {
  my ($self,$v) = @_;
  if(defined $v) {
    $self->{do_not_cleanup} = $v;
  }
  $self->{do_not_cleanup} = 0 unless defined $self->{do_not_cleanup};
  return $self->{do_not_cleanup};
}

=head2 property()

 Used to set key => values in the $self->{properties} namespace,
 for attaching custom properties to jobs

 Args: Key, Value (optional, to set key value)
 Ret: Value of Key
 Example: $job->property("file_written", 1);
          do_something() if $job->property("file_written");

=cut

sub property {
	my $self = shift;
	my $key = shift;
	return unless defined $key;
	my $value = shift;
	if(defined $value){
		$self->{properties}->{$key} = $value;
	}
	return $self->{properties}->{$key};
}

sub DESTROY {
  my $self = shift;
  $self->die if( $self->_die_on_destroy );
  $self->_reap if $self->is_async;
  if( $self->is_cluster ) {
    uncache($self->out_file) unless ref $self->out_file;
    uncache($self->err_file) unless ref $self->out_file;
  }
  $self->cleanup unless $self->_existing_temp || $self->is_async || $self->is_cluster || $self->do_not_cleanup || DEBUG;
}

sub _reap {
  my $self = shift;
  my $hang = shift() ? 0 : WNOHANG;
  if (my $res = waitpid($self->pid, $hang) > 0) {
    # We reaped a truly running process
    $self->_exit_status($?);
    dbp "reaped ".$self->pid;
  } else {
    dbp "reaper: waitpid(".$self->pid.",$hang) returned $res";
  }
}

=head1 SEE ALSO

L<IPC::Run> - the big kahuna

L<IPC::Run3> - this module uses CXGN::Tools::Run::Run3, which is
               basically a copy of this module in which the signal
               handling has been tweaked.

L<Proc::Background> - this module sort of copies this

L<Proc::Simple> - this module takes a lot of code from this

L<Expect> - great for interacting with your subprocess


This module blends ideas from the two CPAN modules L<Proc::Simple> and
L<IPC::Run3>, though it does not directly use either of them.  Rather,
processes are run with L<CXGN::Tools::Run::Run3>, the code of which
has been forked from IPC::Run3 version 0.030.  The backgrounding is
all handled in this module, in a way that was inspired by the way
L<Proc::Simple> does things.  The interface exported by this module is
very similar to L<Proc::Background>, though the implementation is
different.

=head1 AUTHOR

Robert Buels

=cut



package CXGN::Tools::Run::Run3;


# =head1 NAME

# CXGN::Tools::Run::Run3 - modified version of IPC::Run3 version 0.030,
# used by L<CXGN::Tools::Run>.  This module is really only intended for use by
# L<CXGN::Tools::Run>.

# =head1 SYNOPSIS

#     use CXGN::Tools::Run::Run3;    # Exports run3() by default

#     run3 \@cmd, \$in, \$out, \$err;
#     run3 \@cmd, \@in, \&out, \$err;

# =cut

use strict;
use constant debugging => $ENV{CXGNTOOLSRUNDEBUG} || 0;

use Config;

use Carp qw( croak );
use File::Temp qw( tempfile );
use POSIX qw( dup dup2 );

# We cache the handles of our temp files in order to
# keep from having to incur the (largish) overhead of File::Temp
my %fh_cache;

sub _spool_data_to_child {
    my ( $type, $source, $binmode_it ) = @_;

    # If undef (not \undef) passed, they want the child to inherit
    # the parent's STDIN.
    return undef unless defined $source;

    my $fh;
    if ( ! $type ) {
        local *FH;  # Do this the backcompat way
        open FH, "<$source" or croak "$!: $source";
        $fh = *FH{IO};
        warn "run3(): feeding file '$source' to child STDIN\n"
            if debugging >= 2;
    } elsif ( $type eq "FH" ) {
        $fh = $source;
        warn "run3(): feeding filehandle '$source' to child STDIN\n"
            if debugging >= 2;
    } else {
        $fh = $fh_cache{in} ||= tempfile;
        truncate $fh, 0;
        seek $fh, 0, 0;
        my $seekit;
        if ( $type eq "SCALAR" ) {

            # When the run3()'s caller asks to feed an empty file
            # to the child's stdin, we want to pass a live file
            # descriptor to an empty file (like /dev/null) so that
            # they don't get surprised by invalid fd errors and get
            # normal EOF behaviors.
            return $fh unless defined $$source;  # \undef passed

            warn "run3(): feeding SCALAR to child STDIN",
                debugging >= 3
                   ? ( ": '", $$source, "' (", length $$source, " chars)" )
                   : (),
                "\n"
                if debugging >= 2;

            $seekit = length $$source;
            print $fh $$source or die "$! writing to temp file";

        } elsif ( $type eq "ARRAY" ) {
            warn "run3(): feeding ARRAY to child STDIN",
                debugging >= 3 ? ( ": '", @$source, "'" ) : (),
                "\n"
            if debugging >= 2;

            print $fh @$source or die "$! writing to temp file";
            $seekit = grep length, @$source;
        } elsif ( $type eq "CODE" ) {
            warn "run3(): feeding output of CODE ref '$source' to child STDIN\n"
                if debugging >= 2;
            my $parms = [];  # TODO: get these from $options
            while (1) {
                my $data = $source->( @$parms );
                last unless defined $data;
                print $fh $data or die "$! writing to temp file";
                $seekit = length $data;
            }
        }

        seek $fh, 0, 0 or croak "$! seeking on temp file for child's stdin"
            if $seekit;
    }

    croak "run3() can't redirect $type to child stdin"
        unless defined $fh;

    return $fh;
}

sub _fh_for_child_output {
    my ( $what, $type, $dest, $binmode_it ) = @_;

    my $fh;
    if ( $type eq "SCALAR" && $dest == \undef ) {
        warn "run3(): redirecting child $what to oblivion\n"
            if debugging >= 2;

        $fh = $fh_cache{nul} ||= do {
            local *FH;
            open FH, ">" . File::Spec->devnull;
            *FH{IO};
        };
    } elsif ( $type eq "FH" ) {
        $fh = $dest;
        warn "run3(): redirecting $what to filehandle '$dest'\n"
            if debugging >= 3;
    } elsif ( !$type ) {
        warn "run3(): feeding child $what to file '$dest'\n"
            if debugging >= 2;

        local *FH;
        open FH, ">$dest" or croak "$!: $dest";
        $fh = *FH{IO};
    } else {
        warn "run3(): capturing child $what\n"
            if debugging >= 2;

        $fh = $fh_cache{$what} ||= tempfile;
        seek $fh, 0, 0;
        truncate $fh, 0;
    }

    return $fh;
}

sub _read_child_output_fh {
    my ( $what, $type, $dest, $fh, $options ) = @_;

    return if $type eq "SCALAR" && $dest == \undef;

    seek $fh, 0, 0 or croak "$! seeking on temp file for child $what";

    if ( $type eq "SCALAR" ) {
        warn "run3(): reading child $what to SCALAR\n"
            if debugging >= 3;

        # two read()s are used instead of 1 so that the first will be
        # logged even it reads 0 bytes; the second won't.
        my $count = read $fh, $$dest, 10_000;
        while (1) {
            croak "$! reading child $what from temp file"
                unless defined $count;

            last unless $count;

            warn "run3(): read $count bytes from child $what",
                debugging >= 3 ? ( ": '", substr( $$dest, -$count ), "'" ) : (),
                "\n"
                if debugging >= 2;

            $count = read $fh, $$dest, 10_000, length $$dest;
        }
    } elsif ( $type eq "ARRAY" ) {
        @$dest = <$fh>;
        if ( debugging >= 2 ) {
            my $count = 0;
            $count += length for @$dest;
            warn
                "run3(): read ",
                scalar @$dest,
                " records, $count bytes from child $what",
                debugging >= 3 ? ( ": '", @$dest, "'" ) : (),
                "\n";
        }
    } elsif ( $type eq "CODE" ) {
        warn "run3(): capturing child $what to CODE ref\n"
            if debugging >= 3;

        local $_;
        while ( <$fh> ) {
            warn
                "run3(): read ",
                length,
                " bytes from child $what",
                debugging >= 3 ? ( ": '", $_, "'" ) : (),
                "\n"
                if debugging >= 2;

            $dest->( $_ );
        }
    } else {
        croak "run3() can't redirect child $what to a $type";
    }

}

sub _type {
    my ( $redir ) = @_;
    return "FH" if eval { $redir->isa("IO::Handle") };
    my $type = ref $redir;
    return $type eq "GLOB" ? "FH" : $type;
}

sub _max_fd {
    my $fd = dup(0);
    POSIX::close $fd;
    return $fd;
}

my $run_call_time;
my $sys_call_time;
my $sys_exit_time;

sub run3 {

    my $options = @_ && ref $_[-1] eq "HASH" ? pop : {};

    my ( $cmd, $stdin, $stdout, $stderr, $tempdir ) = @_;

    print STDERR "run3(): running ", 
       join( " ", map "'$_'", ref $cmd ? @$cmd : $cmd ), 
       "\n"
       if debugging;

    if($tempdir) {
        open(my $statfile,">","$tempdir/status");
        print $statfile "start:",time,"\n";
    }

    if ( ref $cmd ) {
        croak "run3(): empty command"     unless @$cmd;
        croak "run3(): undefined command" unless defined $cmd->[0];
        croak "run3(): command name ('')" unless length  $cmd->[0];
    } else {
        croak "run3(): missing command" unless @_;
        croak "run3(): undefined command" unless defined $cmd;
        croak "run3(): command ('')" unless length  $cmd;
    }

    my $in_type  = _type $stdin;
    my $out_type = _type $stdout;
    my $err_type = _type $stderr;

    # This routine procedes in stages so that a failure in an early
    # stage prevents later stages from running, and thus from needing
    # cleanup.

    print STDERR "run3(): in_type=$in_type, out_type=$out_type, err_type=$err_type\n"
        if debugging;

    my $in_fh  = _spool_data_to_child $in_type, $stdin,
        $options->{binmode_stdin} if defined $stdin;

    my $out_fh = _fh_for_child_output "stdout", $out_type, $stdout,
        $options->{binmode_stdout} if defined $stdout;

    my $tie_err_to_out =
        defined $stderr && defined $stdout && $stderr eq $stdout;

    my $err_fh = $tie_err_to_out
        ? $out_fh
        : _fh_for_child_output "stderr", $err_type, $stderr,
            $options->{binmode_stderr} if defined $stderr;

    # this should make perl close these on exceptions
    #local *STDIN_SAVE;
    local *STDOUT_SAVE;
    local *STDERR_SAVE;

    my $saved_fd0 = dup( 0 ) if defined $in_fh;

#    open STDIN_SAVE,  "<&STDIN"#  or croak "run3(): $! saving STDIN"
#        if defined $in_fh;
    open STDOUT_SAVE, ">&STDOUT" or croak "run3(): $! saving STDOUT"
        if defined $out_fh;
    open STDERR_SAVE, ">&STDERR" or croak "run3(): $! saving STDERR"
        if defined $err_fh;

    my $ok = eval {
        # The open() call here seems to not force fd 0 in some cases;
        # I ran in to trouble when using this in VCP, not sure why.
        # the dup2() seems to work.
        dup2( fileno $in_fh, 0 )
#        open STDIN,  "<&=" . fileno $in_fh
            or croak "run3(): $! redirecting STDIN"
            if defined $in_fh;

#        close $in_fh or croak "$! closing STDIN temp file"
#            if ref $stdin;

        open STDOUT, ">&" . fileno $out_fh
            or croak "run3(): $! redirecting STDOUT"
            if defined $out_fh;

        open STDERR, ">&" . fileno $err_fh
            or croak "run3(): $! redirecting STDERR"
            if defined $err_fh;

	my $host = `hostname`;
	my ($user) = getpwuid( $< );
	chomp $host;
        my $r = do {

	  my $pid = fork;
	  defined($pid) or die "Could not fork!";
	  unless($pid) {
	    if(ref $cmd) {
	      exec { $cmd->[0] } @$cmd;
	      warn "exec failed for cmd ".join(' ',@$cmd).": $!\n";
	    } else {
	      exec $cmd;
	      warn "exec failed for cmd $cmd: $!\n";
	    }
	    POSIX::_exit(-1); #call a HARD exit to avoid running any weird END blocks
	  }
	  #forward 'stop!' signals to our child process, then heed them ourselves
	  my $we_get_signal; #main screen turn on
	  foreach my $sig (qw/ QUIT INT TERM KILL /) {
	    $SIG{$sig} = sub { kill "SIG$sig" => $pid; $we_get_signal = $sig;};
	  }
	  my $ret = waitpid($pid,0); #wait for child to finish
	  if ($tempdir) {
	    open(my $statfile,">>","$tempdir/status");
	    print $statfile "end:",time,"\n";
	    print $statfile "ret:$?\n";
	    print $statfile "host:$host\n";
	  }
	  die "Got signal SIG$we_get_signal\n" if $we_get_signal;
	  #how are you gentlemen!
	  $ret
	};

	my $exval = $? >> 8;
	my $sig = $?&127;
        unless ( defined $r && $r != -1 && $exval == 0 && $sig == 0) {
	  if ( debugging ) {
	    my $err_fh = defined $err_fh ? \*STDERR_SAVE : \*STDERR;
	    print $err_fh "run3(): system() error $!\n"
	  }

	  my @signames = split / /,$Config{sig_name};
	  die "Command failed on host '$host', user '$user', with \$?=$?, exit value $exval, signal $signames[$sig] ($sig), \$r=$r, \$!='$!' (string could be spurious)\n";
        }

        if ( debugging ) {
            my $err_fh = defined $err_fh ? \*STDERR_SAVE : \*STDERR;
            print $err_fh "run3(): \$? is $?, \$r is $r\n"
        }
        1;
    };
    my $x = $@;

    my @errs;

    if ( defined $saved_fd0 ) {
        dup2( $saved_fd0, 0 );
        POSIX::close( $saved_fd0 );
    }

#    open STDIN,  "<&STDIN_SAVE"#  or push @errs, "run3(): $! restoring STDIN"
#        if defined $in_fh;
    open STDOUT, ">&STDOUT_SAVE" or push @errs, "run3(): $! restoring STDOUT"
        if defined $out_fh;
    open STDERR, ">&STDERR_SAVE" or push @errs, "run3(): $! restoring STDERR"
        if defined $err_fh;

    die join ", ", @errs,"\n" if @errs;

    die "$x\n" unless $ok;

    _read_child_output_fh "stdout", $out_type, $stdout, $out_fh, $options
        if defined $out_fh && $out_type && $out_type ne "FH";
    _read_child_output_fh "stderr", $err_type, $stderr, $err_fh, $options
        if defined $err_fh && $err_type && $err_type ne "FH" && !$tie_err_to_out;

    return 1;
}

# =head1 AUTHORS

# Barrie Slaymaker E<lt>C<barries@slaysys.com>E<gt>.

# Ricardo SIGNES E<lt>C<rjbs@cpan.org>E<gt> performed some routine maintenance in
# 2005, thanks to help from the following ticket and/or patch submitters: Jody
# Belka, Roderich Schupp, David Morel, and anonymous others.

# Robert Buels E<lt>C<rmb32@cornell.edu>E<gt> then gutted and lobotomized it
# for his own nefarious purposes.

# =cut

###
1;#do not remove
###


