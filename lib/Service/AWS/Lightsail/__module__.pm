#!/usr/bin/perl

use Cwd;
use Paws;
use Rex -feature => [qw/1.4/];
use Rex::Commands::Rsync;
use Rex::Commands::File;
use File::Basename;
use Time::Ago;
use Data::Dumper qw(Dumper);
use Time::Stamp localstamp => { -as => 'ltime', format => 'compact' };
use Time::ParseDate;
use DateTime::Format::Strptime qw(strftime);
use JSON::Parse 'parse_json';

my $server = '';
my $server_name = '';

Rex::Config->set_path([Rex::Config->get_path, '/opt/bitnami/mysql/bin']);
Rex::Config->set_verbose_run(1);

# common vars
my $wp_root = '/home/bitnami/apps/wordpress/htdocs';

task 'test', sub {
  print Dumper \@_;
#  my @blah = Rex::Config->get_path;
#  say @blah;
#  do_task('wp_maint_mode_off');
#  my $from_dir = '/home/bitnami/apps/wordpress/htdocs/wp-content';
#  my $to_dir = '/home/bitnami/ress/htdocs';
#  sudo TRUE;
#  sync ($from_dir, $bu_files, { download => 1, parameters => '--delete --archive' });
  #say 'hello';
  #die if $?;
  #say 'kjsdkjfd'; #  file '/home/bitnami/backups2', ensure => 'directory', on => '<local>';
#my $server = $server->name;
  #run_task('test2', params => { 'blah' => 'blah2' });
#  run_task('test2', params => [ 'blah' ]);

};

task 'test2', sub {
  do_task('test');
};



### WP STUFF ##########################
desc 'report wordpress version';
task 'wp_rpt_version', sub {
  my $remote_version = wp('core version');
  my $local_version;
  LOCAL {
    $local_version = wp('core version', 1);
  };
  if ($remote_version && $remote_version eq $local_version) {
    say "WordPress versions match: $remote_version";
  } else {
    say "WordPress version on " . $server . ": $remote_version";
  }
};

desc 'Report WordPress credentials';
task 'wp_rpt_credentials', sub {
  my @credentials = run('cat ~/bitnami_application_password');
  my $credentials = join "\n", @credentials;

  say $credentials;
};

desc "Dump remote database";
task 'dump_remote_db', sub {
  my $file = '/home/bitnami/mysql_dumps/latest.sql';
  my $remote_dir = '/home/bitnami/mysql_dumps';
  file $remote_dir, ensure => 'directory', on => $server;
  run 'mv latest.sql backup.sql', cwd => $remote_dir;
  run './dump_mysql.sh',          cwd => $remote_dir;
  my %fs = stat($file);
  if ( is_file($file) && $fs{size} > 0 ) {
    return 1;
  } else {
    return 0;
  }
};

desc 'backup WordPress';
task 'wp_backup', sub {
  my $live_bu = $_[0]->{lc('maint_mode')} ? 0 : 1;
  my $bu_type = $_[0]->{lc('type')} || 'reg_backup';
  my $maint_remain = $_[0]->{lc('maint_remain')};

  # create backup directory
  my $time = ltime();
  my $bu_dir = "/home/bitnami/backups/$server";
  my $skip_maint_mode = $live_bu;

  LOCAL {
    file '/home/bitnami/backups', ensure => 'directory';
    my $dir_does_not_exist = !is_dir($bu_dir);
    file $bu_dir, ensure => 'directory';
    if ($dir_does_not_exist) {
      run_task('git_init', params => { dir => $bu_dir });
    }
  };

  # Get maintenance mode status. Pretend we are already in maintenance mode
  # to keep site online while doing backup
  my $maint_status = $skip_maint_mode || run_task('wp_rpt_maint_mode', on => $server, params => { quiet => 1 } );

  $? = '';
  run_task('wp_maint_mode_on', on => $server) if !$maint_status;
  if ($?) {
    run_task('wp_maint_mode_off', on => $server ) if !$maint_status;
    die 'Could not place site into maintenance mode. Aborting backup.';
  }

  my $r_file = '/home/bitnami/mysql_dumps/latest.sql';
  my $db_file = "$bu_dir/db/db.sql";
  my $dump_success = run_task('dump_remote_db', on => $server);
  if (!$dump_success) {
    run_task('wp_maint_mode_off', on => $server) if !$maint_status;
    die 'Could not dump remote database. Placing site back online and aborting backup.';
  }
  download $r_file, $db_file;

  my $bu_files = "$bu_dir/wp";
  my $from_dir = '/home/bitnami/apps/wordpress/htdocs/';

  # rsync WordPress site from remote server
  sudo TRUE;
  sync ($from_dir, $bu_files, { download => 1, parameters => '--delete --archive' });
  sudo FALSE;


  # done with backup restore site
  run_task('wp_maint_mode_off', on => $server) unless $maint_status || $maint_remain;

  # commit the changes to git
  LOCAL {
    run ('git add .', cwd => $bu_dir);
    run ("git commit -m '$bu_type|$time'", cwd => $bu_dir);
    run ("git tag '$bu_type|$time'", cwd => $bu_dir);
  };
};


### Updating
desc 'upgrade WordPress';
task 'wp_upgrade', sub {
  if (wp('core check-update') == 1) {
    say 'WordPress is on most recent version.';
    return;
  }

  run_task('wp_backup', on => $server, params => { maint_mode   => 1,
                                                   maint_remain => 1,
                                                   type         => 'wp_upgrade' });
  my $success = wp('core update');
  run_task('wp_maint_mode_on', on => $server);
  #TODO: if $success != 1, restore backup
  $success = wp('core update-db');
  #TODO: if $success != 1, restore backup
  run_task('wp_maint_mode_off', on => $server);
};

desc 'update all WP plugins';
task 'wp_update_all_plugins', sub {
  my $count = wp('plugin list --update=available --format=count');
  if (!$count) {
    say 'No plugins require an update';
    return;
  }

  $count = wp('plugin list --update=available --status=active --format=count');
  if ($count) {
    run_task('wp_backup', on => $server, params =>{ type => 'plugin_upgrade' });
  }

  #TODO: do something if $output != 1
  my $output = wp('plugin update --all');
};

desc 'update all WP themes';
task 'wp_update_all_themes', sub {
  my $count = wp('theme list --update=available --format=count');
  if (!$count) {
    say 'No themes require an update';
    return;
  }

  $count = wp('theme list --update=available --status=active --format=count');
  if ($count) {
    run_task('wp_backup', on => $server, params =>{ type => 'theme_upgrade' });
  }

  #TODO: do something if $output != 1
  my $output = wp('theme update --all');
};


### Rolling back
desc 'rollback wordpress site';
task 'wp_rollback', sub {
  my $hash = $_[0]->{lc('hash')};
  my $from_dir = "/home/bitnami/backups/$server/wp/";

  LOCAL { run("git checkout $hash", cwd => "/home/bitnami/backups/$server"); };

  sudo TRUE;
  sync ($from_dir, $wp_root, { upload => 1, parameters => '--delete --archive' });
  sudo FALSE;

  # cp db file to remote server
  file '/home/bitnami/db.sql',
    source    => "/home/bitnami/backups/$server/db/db.sql",
    on_change => sub {
      run "mysql bitnami_wordpress < '/home/bitnami/db.sql'";
    };

  LOCAL { run("git checkout master", cwd => "/home/bitnami/backups/$server"); };
  my $success = wp('core update-db');
  #TODO: if $success != 1, restore backup
};

desc 'rollback WP to oldest backup';
task 'wp_rollback_to_oldest', sub {
  my $hash = run_task('git_get_oldest_backup');

  run_task('wp_rollback', on => $server, params => { hash => $hash } );
};

desc 'rollback WP to latest backup';
task 'wp_rollback_to_newest', sub {
  LOCAL { run("git checkout master", cwd => "/home/bitnami/backups/$server"); };
  run_task('wp_rollback', on => $server );
};

desc 'select WP backup';
task 'wp_rollback_to_selected', sub {
  my $hash = run_task('git_list_backups', on => $server, params => { select => 1 });
  run_task('wp_rollback', on => $server, params => { hash => $hash } );
};


### Maintenance mode functions
desc 'report whether a site is in maintenance mode';
task 'wp_rpt_maint_mode', sub {
  my $quiet = $_[0]->{lc('quiet')} ? 1 : 0;
  my $is_active = wp("maintenance-mode status");
  my $return = $is_active =~ /is not active/ ? 0 : 1;
  say $is_active if !$quiet;
  return $return;
};

desc 'toggle wordpress maintance mode';
task 'wp_maint_toggle', sub {
  my $is_active = run_task('wp_rpt_maint_mode', on => $server, params => { quiet => 1} );
  say 'Toggling maintenance mode';
  if ($is_active) {
    wp('maintenance-mode deactivate');
  } else {
    wp('maintenance-mode activate');
  }
  run_task('wp_rpt_maint_mode', on => $server, params => { quiet => 1 });
};

desc 'turn wordpress site maintenance mode on';
task 'wp_maint_mode_on', sub {
  my $is_active = run_task('wp_rpt_maint_mode', on => $server, params => { quiet => 1 } );
  if ($is_active) {
    say 'Maintenance mode already active. Doing nothing';
  } else {
    my $success = wp('maintenance-mode activate');
    if ($success =~ 'is not active') {
      die 'Could not place site into maintenance mode. Aborting.';
    }
    say 'WordPress maintenance mode ON, site is offline.';
  }
};

desc 'turn wordress site maintenance mode off';
task 'wp_maint_mode_off', sub {
  my $is_active = run_task('wp_rpt_maint_mode', on => $server, params => { quiet => 1 });
  if ($is_active) {
    my $out = wp('maintenance-mode deactivate');
    if (!$out) {
      die 'Could take site out of maintenance mode.';
    } else {
      say 'WordPress maintenance mode is OFF, site is live.';
    }
  } else {
    say 'Maintenance mode already inactive. No action taken.';
  }
};


### Configuration
desc "rsync wordpress content folder";
task 'wp_rsync_content_folder', sub {
  my $from_dir = '/home/bitnami/apps/wordpress/htdocs/wp-content';
  my $to_dir = '/home/bitnami/apps/wordpress/htdocs';

  #sync ($rdir, $ldir, { download => 1, parameters => '--delete --verbose' });
};

desc 'install WordPress plugin';
task 'wp_install_plugin', sub {
  my $plugins = $_[1];
  foreach my $plugin (@$plugins) {
    if ($plugin eq 'wp-super-cache') {
      file "$wp_root/wp-content/wp-cache-config.php", ensure => 'absent';
    }
    run wp("plugin install $plugin --activate");
  }
};

desc 'remove bitnami branding';
task 'wp_remove_bitnami_link', sub {
  run('sudo /opt/bitnami/apps/wordpress/bnconfig --disable_banner 1');
};

desc 'fix wordpress perms';
task 'wp_fix_perms', sub {
  run "sudo chown -R bitnami:daemon $wp_root";
  run "sudo find $wp_root -type d -exec chmod 775 {} \;";
  run "sudo find $wp_root -type f -exec chmod 664 {} \;";
  run "sudo chmod 640 $wp_root/wp-config.php";
};



### GIT STUFF ########################
desc 'initialize a git repo';
task 'git_init', sub {
  my $dir = $_[0]->{dir} || $_[1]->[0];
  die 'No directory passed to git_init. git was not initted.' if !$dir;
  my $output = run "git status", cwd => $dir;

  if ($output =~ /On branch/) {
    return;
  }
  run 'git init .', cwd => $dir;
};

desc 'list all WP backups';
task 'git_list_backups', sub {
  my $quiet = $_[0]->{lc('quiet')} ? 1 : 0;
  my $select = $_[0]->{lc('select')} ? 1 : 0;
  my @output;
  die ('No server specified') if $server eq '<local>';
  LOCAL { @output = run('git log --pretty=format:\'%H|%s\'', cwd => "/home/bitnami/backups/$server"); };

  my %commits;
  my $strp = DateTime::Format::Strptime->new(
    pattern => '%Y%m%d_%H%M%S',
    time_zone => 'GMT',
  );
  my $tz = DateTime::TimeZone->new( name => 'America/New_York' );
  my $count = 1;
  foreach my $commit (@output) {
    my @parts = split /[\| ]/, $commit;
    $commits{$count}{hash} = $parts[0];
    $commits{$count}{type} = $parts[1];
    $commits{$count}{date} = $parts[2];
    if (!$quiet) {
      my $dt = $strp->parse_datetime($parts[2]);
      my $offset = $tz->offset_for_datetime($dt);
      my $dur = DateTime::Duration->new(seconds => $offset);
      my $ts = parsedate($dt);
      my $words = Time::Ago->in_words(time() - $ts);
      printf("%4d %s %20s %20s %20s\n", $count++, $parts[0], $parts[1], "$words ago", strftime('%m-%d-%y %l:%M %p', $dt->add_duration($dur)));
      if ($count > 50) {
        print "Printing only last 50 backups.\n";
        last;
      }
    }
  }

  my $valid_input = 0;
  my $selection = 0;
  while ($select && !$valid_input) {
    print "\nSelect a backup to restore: ";
    $selection = <STDIN>;
    chomp $selection;
    $valid_input = $selection > 0 && $selection <= $count;
    print "Invalid selection. Try again.\n" if !$valid_input;
  }

  if ($selection) {
    return $commits{$selection}{hash};
  }

  return \%commits;
};

desc 'get oldest backup';
task 'git_get_oldest_backup', sub {
  my $commits = run_task('git_list_backups', params => { quiet => 1 } );
  my @sorted;

  foreach my $c (sort { $commits->{$b}{date} cmp $commits->{$a}{date} } keys %$commits) {
    push @sorted, $c;
  }

  return pop @sorted;
};




### SERVER ADMIN STUFF ##############
desc 'restart the stack on an instance';
task 'restart_stack', sub {
  run 'sudo /opt/bitnami/ctlscript.sh restart';
};

desc 'restart apache';
task 'restart_apache', sub {
  run('sudo /opt/bitnami/ctlscript.sh restart apache');
};

desc "Import database";
task "import_remote_db", sub {
  my $file = '/home/bitnami/mysql_dumps/latest.sql';
  my $dump_success = do_task('dump_remote_db');
  die 'Unable to dump remote database' if !$dump_success;
  run "rm $file";
  download $file, '~/mysql_dumps/latest.sql';
  run "mysql bitnami_wordpress < $file";
};

desc 'report uptime';
task 'uptime', sub {
  say run 'uptime';
};

desc 'tail the apache error log';
task 'tail_apache_error', sub {
  my @lines = run 'tail /opt/bitnami/apache2/logs/error_log';
  foreach my $line (@lines) {
    $line =~ s/] \[/]\n\[/g;
    $line =~ s/] ([[:alpha:]])/]\n$1/;
    print "$line\n\n";
  }
};

desc 'update hosts file';
task 'add_host_entry', sub {
  my $host = $_[0];
  my $ip   = $_[1];
  sudo {
    command => sub {
      host_entry $host,
      ensure => 'present',
      ip     => $ip,
      on_change => sub { say 'added host entry'; };
    },
    user => 'root'
  };
};

desc 'perfrom a system update with no snapshot';
task "update_system_quick", sub {
  if ($server eq '<local>') {
    die 'No host passed to task. Aborting.';
  }
  sudo {
    command => sub {
      update_system;
    },
    user => 'root'
  };

};

desc 'perform a system update with snapshot';
task "update_system_full", sub {
  if ($server eq '<local>') {
    die 'No host passed to task. Aborting.';
  }
  my $snapshot_name = run_task('instance_snapshot', on => $server, params => { name => 'pre_update', wait => 1 } );
  if (!$snapshot_name) {
    die 'Unable to take instance snapshot. Aborting.';
  }

  run_task('update_system_quick', on => $server);
};

desc 'delay code execution until snapshot is available';
task 'snapshot_wait', sub {
  my $snapshot_name = $_[0];
  die ('No snapshot name provided.') if !$snapshot_name;

  my $snapshot_exists = 0;
  my $loop_count = 0;
  my $instances;
  while (!$snapshot_exists && $loop_count < 120) {
    sleep 5;
    say 'Checking to see if snapshot is ready.';
    $instances = run_task('get_all_instance_snapshots', on => $server),
    $snapshot_exists = grep { $snapshot_name eq $_->Name && $_->State eq 'available' } @$instances;
    $loop_count++;
  }

  if ($loop_count >= 120) {
    die 'Snapshot process taking greater than 10 min. Something may be wrong. Aborting.';
  }
};

desc 'sync directory with remote machine';
task 'rsync_up', sub {
  my $parameters = shift;
  my $dir = $parameters->{dir};

  if ($dir eq '.') {
    $dir = cwd;
  }

  if (! -d $dir) {
    die 'Directory does not exist. Aborting.';
  }

  my $from_dir = $dir;
  my($leaf_dir, $to_dir, $suffix) = fileparse($from_dir);

  sync ($from_dir, $to_dir, { upload => 1, parameters => '--delete --verbose' });
};

desc 'distribute file from local to remove server';
task 'file_distribute', sub {
  my $file;
  if (ref $_[0] eq 'HASH' && $_[0]->{file}) {
    if ($_[0]->{file}) {
      $file = $_[0]->{file};
    }
  } elsif (@{$_[1]}) {
    $file = $_[1]->[0];
  } elsif ($_[0]) {
    $file = $_[0];
  }
  say $file;

  die ('No file passed to task. Aborting.') if !$file;

  if (!-f $file) {
    die ('File does not exist on the local serve. Aborting.');
  }

  file $file,
    source => $file;
};

desc 'remove file server';
task 'file_undistribute', sub {
  my $file;
  if (ref $_[0] eq 'HASH' && $_[0]->{file}) {
    if ($_[0]->{file}) {
      $file = $_[0]->{file};
    }
  } elsif (@{$_[1]}) {
    $file = $_[1]->[0];
  } elsif ($_[0]) {
    $file = $_[0];
  }
  say $file;

  die ('No file passed to task. Aborting.') if !$file;

  file $file,
    ensure => 'absent';
};

desc 'add wordpress user/pass to my.cnf file';
task 'wp_credentials_to_mysql_conf', sub {
  my $perl = parse_json(wp('config list DB_PASSWORD --fields=value --format=json'));

  my $pw = $perl->[0]{value};
  my $user = 'bn_wordpress';

  my $append = "\n[client]\nuser=$user\npassword=$pw\n";

  # delete_lines_matching
  # delete_lines_matching "/var/log/auth.log" => "root";

  my $dir = '/opt/bitnami/mysql/bitnami';
  my @sizes = qw( 2xlarge large medium micro small xlarge );

  foreach my $size (@sizes) {
    my $file = "$dir/my-$size.cnf";
    delete_lines_matching $file => '[client]';
    delete_lines_matching $file => 'user=';
    delete_lines_matching $file => 'password=';
    my $fh;
    eval {
      $fh = file_append("$dir/my-$size.cnf");
    };

    if($@) {
      print "An error occured. $@.\n";
    }

    $fh->write($append);
    $fh->close;

    file $file, mode => 600;
  }

};




### LIGHTSAIL MANAGEMENT ############
desc 'create lightsail instance';
task 'instance_create', sub {
  my $size = $_[0]->{size};
  my $name = $_[0]->{name};
  my $region = $_[0]->{region};

  if (!$size || !$name || !$region) {
    print "No --size argument.\n" if !$size;
    print "No --name argument.\n" if !$name;
    print "No --region argument.\n" if !$region;
    die ('Missing arguments. Aborting.');
  }

  die 'Unknown region. Aborting.' if ($region !~ /^us-west-2|us-east-1|us-east-2|west-2|east-1|east-2$/);
  if ($region !~ /^us/) {
    $region = 'us-' . $region;
  }

  # overwrite default Paws service to be sure we can create instance
  $service = Paws->service('Lightsail', region => $region);


  my $regions = run_task('get_aws_availability_zones');
  my $available = grep { $region =~ /$_/ } @$regions;
  if (!$available) {
    die ('Supplied region is not available from this server. Available regions: ' . join ' ', @$regions);
  }


  if ($size !~ /^nano|micro|small|medium|large|xlarge|2xlarge$/) {
    die ('Uknown size. Size must nano, micro, small, medium, large, xlarge, 2xlarge');
  }

  my $result = $service->CreateInstances(
    AvailabilityZone => $region,
    BlueprintId => 'wordpress',
    BundleId => $size . '_2_0',
    InstanceNames => [ $name ],
  );

  my $instance_exists = 0;
  my $loop_count;
  while (!$instance_exists && $loop_count < 120) {
    sleep 5;
    say 'Checking to see if instance is ready.';
    my $instances = run_task('instances_list', on => $server);
    $instance_exists = grep { $name eq $_->Name && $_->State->Name eq 'pending' } @$instances;
    $loop_count++;
  }

  say 'Instance created!';
};

desc 'return list of zones that are available from aws';
task 'get_aws_availability_zones', sub {
  my $json = run('aws lightsail get-regions --include-availability-zones --no-include-relational-database-availability-zones');

  my $perl = parse_json($json);
  my $azones = $perl->{regions};

  my @zones;
  foreach my $z (@$azones) {
    if (@{$z->{availabilityZones}}) {
      foreach my $zone (@{$z->{availabilityZones}}) {
        push @zones, $zone->{zoneName};
      }
    }
  }

  return \@zones;
};

desc 'delete lightsail instance';
task 'instance_delete', sub {
  my $instance = $_[0]->{instance} || $_[1]->[0];
  die ('No instance name provided. Aborting.') if !$instance;
  die ('No instance by that name exists. Aborting.')
    if !run_task('instance_exists', params => { instance => $instance } );

  my $result = $service->DeleteInstance(
    InstanceName => $instance,
  );
};

desc 'determine if instance exists';
task 'instance_exists', sub {
  my $instance = $_[0]->{instance} || $_[1]->[0];
  my $instances = run_task('instances_list', params => { quiet => 1 } );
  return grep { $_->Name eq $instance } @$instances;
};

desc 'reboot instance';
task 'instance_reboot', sub {
  my $instance = $_[0]->{instance} || $_[1]->[0];

  my $exists = run_task('instance_exists', params => { instance => $instance } );
  die ('That instance does not exist. Aborting.') if !$exists;

  my $results = $service->RebootInstance(
    InstanceName => $instance,
  );
};

desc 'lists all lightsail instances';
task 'instances_list', sub {
  my $quiet = $_[0]->{lc('quiet')} ? 1 : 0;
  my $instances = $service->GetInstances->Instances;
  if (!$quiet) {
    foreach my $instance (@$instances) {
      #print Dumper $instance;
      printf("%-30s %15s %15s\n", $instance->Name, $instance->PublicIpAddress, $instance->PrivateIpAddress);
    }
  }

  return $instances;
};

desc 'update hosts file';
task 'update_hosts', sub {
  my $instances = run_task('instances_list');
  foreach my $i (@$instances) {
    my $name = $i->Name;
    my $priv_ip = $i->PrivateIpAddress;
    my $pub_ip = $i->PublicIpAddress;
    run_task('add_host_entry', on => $server, params => [ $name, $priv_ip ]);
  }
};

desc 'snapshot a disk';
task 'take_disk_snapshot', sub {
  $service->CreateDiskSnapshot(DiskSnapshotName => 'test', InstanceName => $server);
};

desc 'snapshot an instance';
task 'instance_snapshot', sub {
  my $snapshot_name = ltime() . '_snapshot';
  use Data::Dumper qw(Dumper);
  my $wait;
  if (ref $_[0] eq 'HASH' && $_[0]->{name}) {
    if ($_[0]->{name}) {
      $snapshot_name = $snapshot_name .= '_' . $_[0]->{name};
    }
    if ($_[0]->{wait}) {
      $wait = 1;
    }
  } elsif (@{$_[1]}) {
    $snapshot_name .= '_' . $_[1]->[0];
  } elsif ($_[0]) {
    $snapshot_name .= '_' . $_[0];
  }

  say "Taking snapshot named: $snapshot_name";
  my $result = $service->CreateInstanceSnapshot(InstanceSnapshotName => $snapshot_name, InstanceName => $server);
  if ($wait) {
    $? = '';
    run_task('snapshot_wait' => params => [ $snapshot_name ]);
    die ('Could not create snapshot') if $?;
  }

  return $result ? $snapshot_name : '';
};

desc 'returns array ref to all snapshots or to all snapshots on an instances';
task 'get_all_instance_snapshots', sub {
  my @snaps;
  my $page_token = 'the_beginning';
  while ($page_token) {
    my $result;
    if ($page_token eq 'the_beginning') {
      $page_token = 0;
    }
    if ($page_token) {
      $result = $service->GetInstanceSnapshots(
        PageToken => $page_token,
      );
    } else {
      $result = $service->GetInstanceSnapshots;
    }
    push @snaps, @{$result->InstanceSnapshots};
    $page_token = $result->NextPageToken;
  }
  if ($server ne '<local>') {
    @snaps = grep { $server eq $_->FromInstanceName } @snaps;
  }
  return \@snaps;
};

desc 'dumps all instance snapshots to screen';
task 'dump_all_instance_snapshots', sub {
  my $snaps = run_task('get_all_instance_snapshots', on => $server);
  print Dumper $snaps;
};

desc 'return the most recent instance snapshot';
task 'get_latest_instance_snapshot', sub {
  my $snaps = run_task('get_all_instance_snapshots', on => $server);
  my $newest = 0;
  foreach my $snap (@$snaps) {
    my $time = $snap->CreatedAt;
    if ($newest) {
      if ($time > $newest->CreatedAt) {
        $newest = $snap;
      }
    } else {
      $newest = $snap;
    }
  }
  return $newest;
};

desc 'dump the object of the most recently created instance object to the screen';
task 'dump_latest_instance_snapshot', sub {
  my $snap = run_task('get_latest_instance_snapshot', on => $server);
  print Dumper $snap;

};

desc 'tag an instance';
task 'tag_instance', sub {
  my $args = $_[1];
  my $instance = shift @$args;
  my @tags = @$args;

  my $instances = run_task('instances_list' => params { quiet => 1 });

  my $instance_exists;
  foreach my $i (@$instances) {
    if ($instance eq $i->Name) {
      $instance_exists = 1;
      last;
    }
  }

  if (!$instance_exists) {
    die "No instances by the name $instance exist. Aborting.";
  }

  my @new_tags;
  foreach my $tag (@tags) {
    push @new_tags, { Key => $tag };
  }

  $service->TagResource(
    ResourceName => $instance,
    Tags => \@new_tags,
  );
};

# manage ip addresses
desc 'get static ip address';
task 'ip_get_static', sub {
  my $name = $_[0]->{name} || $_[1]->[0];
  die ('No static ip name supplied. Aborting.') if !$name;
  my $result = $service->GetStaicIp(
    StaticIpName => $name,
  );

  return $result->StaticIp;
};

desc 'list all static ip addresses';
task 'ips_list', sub {
  my $quiet = $_[0]->{lc('quiet')} ? 1 : 0;
  my $ips = $service->GetStaticIps;

  if (!$quiet) {
    foreach my $i (@{$ips->{StaticIps}}) {
      printf("%-15s %10s %18s\n", $i->Name, $i->IsAttached ? 'Attached' : 'Unattached', $i->IpAddress);
    }
  }
  return $ips;
};

desc 'determine if static ip can be attached';
task 'ip_is_available', sub {
  my $ip_name = $_[0]->{ip_name} || $_[1]->[0];

  my $ips = run_task('ips_list', params => { queit => 1 });
  print Dumper $ips;

  my $available = grep { $_->Name eq $ip_name && !$_->IsAttached } @{$ips->StaticIps};
  if (!$available) {
    run_task('ips_list');
    return 0;
  }

  return 1;

};

desc 'attach a static ip to an instance';
task 'ip_attach', sub {
  my $ip = $_[0]->{ip};
  my $instance = $_[0]->{instance};

  die 'No instance name passed' if !$instance;
  die 'No ip name passed' if !$ip;

  my $exists = run_task('instance_exists', params => { instance => $instance });

  if (!$exists) {
    run_task('instances_list' => params => { quiet => 0 } );
    die ('Supplied instance does not exist. Aborting.');
  }

  my $available = run_task('ip_is_available', params => { ip_name => $ip });
  die ('That IP address does not exist or is already attached. Aborting.') if !$available;

  my $result = $service->AttachStaticIp(
    InstanceName => $instance,
    StaticIpName => $ip,
  );

};

# manage domains
desc 'create a domain';
task 'domain_create', sub {
  my $domain = $_[0]->{name} || $_[1]->[0];
  die ('No domain supplied. Aborting.') if !$domain;

  # creating domains available only in east region
  $service = Paws->service('Lightsail', region => 'us-east-1');
  my $res = $service->CreateDomain(
    DomainName => $domain,
  );

};



before_task_start qr{test\d} => sub {
  #say 'hi';
};

before_task_start 'ALL' => sub {
  $server = $_[0]->server->[0]->name;
};

sub wp {
  my $cmd   = shift;
  my $local = shift;
  my $auto_die = shift;
  my $wp_cmd = '/opt/bitnami/apps/wordpress/bin/wp';
  if (!$cmd) {
    die 'No command passed to wp_cmd';
  }
  my @out;
  if ($local) {
    LOCAL {
      @out = (run("$wp_cmd $cmd", cwd => $wp_root, auto_die => $auto_die));
    };
  } else {
    @out = (run("$wp_cmd $cmd", cwd => $wp_root, auto_die => $auto_die));
  }
  my $out = join "\n", @out;
  if ($out !~ /^Success/m) {
    return $out;
  } else {
    return 1;
  }
}

1;
