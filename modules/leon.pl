#!/usr/bin/perl
# $Id$
#

use English;
use oar_iolib;
use Sys::Hostname;
use oar_conflib qw(init_conf dump_conf get_conf is_conf);
use IPC::Open2;
use IPC::Open3;
use Data::Dumper;
use oar_Judas qw(oar_debug oar_warn oar_error set_current_log_category);
use IO::Socket::INET;
use oar_Tools;

# Log category
set_current_log_category('main');

init_conf($ENV{OARCONFFILE});
my $Server_hostname = get_conf("SERVER_HOSTNAME");
my $Server_port = get_conf("SERVER_PORT");

my $Deploy_hostname = get_conf("DEPLOY_HOSTNAME");
if (!defined($Deploy_hostname)){
    $Deploy_hostname = $Server_hostname;
}

my $Cosystem_hostname = get_conf("COSYSTEM_HOSTNAME");
if (!defined($Cosystem_hostname)){
    $Cosystem_hostname = $Server_hostname;
}

my $Server_epilogue = get_conf("SERVER_EPILOGUE_EXEC_FILE");

my $Openssh_cmd = get_conf("OPENSSH_CMD");
$Openssh_cmd = oar_Tools::get_default_openssh_cmd() if (!defined($Openssh_cmd));

if (is_conf("OAR_SSH_CONNECTION_TIMEOUT")){
    oar_Tools::set_ssh_timeout(get_conf("OAR_SSH_CONNECTION_TIMEOUT"));
}

if (is_conf("OAR_RUNTIME_DIRECTORY")){
    oar_Tools::set_default_oarexec_directory(get_conf("OAR_RUNTIME_DIRECTORY"));
}

my $Exit_code = 0;

my $base = iolib::connect();

#do it for all job in state LEON in the data base table fragJobs
iolib::lock_table($base,["jobs","job_state_logs","resources","assigned_resources","frag_jobs","event_logs","moldable_job_descriptions","job_types","job_resource_descriptions","job_resource_groups","challenges","job_dependencies","gantt_jobs_predictions"]);

foreach my $j (iolib::get_to_kill_jobs($base)){
    if (iolib::is_job_desktop_computing($base,$j->{job_id})) {
        oar_debug("[Leon] Job $j->{job_id} is affected to a DesktopComputing resource, I do not handle it\n");
        next;
    }

    oar_debug("[Leon] Normal kill : I treate the job $j->{job_id}\n");
    if (($j->{state} eq "Waiting") || ($j->{state} eq "Hold")){
        oar_debug("[Leon] Job is not launched\n");
        iolib::set_job_state($base,$j->{job_id},"Error");
        iolib::set_job_message($base,$j->{job_id},"job killed by Leon directly");
        if ($j->{job_type} eq "INTERACTIVE"){
            oar_debug("[Leon] I notify oarsub in waiting mode\n");
            #answer($Jid,$refJob->{'infoType'},"JOB KILLED");
            my ($addr,$port) = split(/:/,$j->{info_type});
            if (!defined(oar_Tools::notify_tcp_socket($addr, $port, "JOB KILLED"))){
                oar_debug("[Leon] Notification done\n");
            }else{
                oar_debug("[Leon] Cannot open connection to oarsub client for job $j->{job_id}, it is normal if user typed Ctrl-C !!!!!!\n");
            }
        }
        $Exit_code = 1;
    }elsif (($j->{state} eq "Terminated") || ($j->{state} eq "Error") || ($j->{state} eq "Finishing")){
        oar_debug("[Leon] Job is terminated or is terminating I do nothing\n");
    }else{
        my $types = iolib::get_current_job_types($base,$j->{job_id});
        my @hosts = iolib::get_job_current_hostnames($base,$j->{job_id});
        my $host_to_connect_via_ssh = $hosts[0];
        #deploy, cosystem and no host part
        if ((defined($types->{cosystem})) or ($#hosts < 0)){
            $host_to_connect_via_ssh = $Cosystem_hostname;
        }elsif (defined($types->{deploy})){
            $host_to_connect_via_ssh = $Deploy_hostname;
        }
        #deploy, cosystem and no host part
        if (defined($host_to_connect_via_ssh)){
            iolib::add_new_event($base,"SEND_KILL_JOB",$j->{job_id},"[Leon] Send kill signal to oarexec on $host_to_connect_via_ssh for the job $j->{job_id}");
            oar_Tools::signal_oarexec($host_to_connect_via_ssh, $j->{job_id}, "TERM", 0, $base, $Openssh_cmd, '');
        }
    }
    iolib::job_arm_leon_timer($base,$j->{job_id});
}

#I treate jobs in state EXTERMINATED in the table fragJobs
foreach my $j (iolib::get_to_exterminate_jobs($base)){
    oar_debug("[Leon] EXTERMINATE the job $j->{job_id}\n");
    iolib::set_job_state($base,$j->{job_id},"Finishing");
    if ($j->{start_time} == 0){
        iolib::set_running_date($base,$j->{job_id});
    }
    iolib::set_finish_date($base,$j->{job_id});
    iolib::set_job_message($base,$j->{job_id},"job exterminated by Leon");
    iolib::job_arm_leon_timer($base,$j->{job_id});
    $Exit_code = 2;

    $SIG{PIPE}  = 'IGNORE';
    my $pid = fork();
    if ($pid == 0){
        #CHILD
        undef($base);
        $SIG{USR1} = 'IGNORE';
        $SIG{INT}  = 'IGNORE';
        $SIG{TERM} = 'IGNORE';
        my $str = "[Leon] I exterminate the job $j->{job_id}";
        my @events;
        push(@events, {type => "EXTERMINATE_JOB", string => $str});
        my $dbh = iolib::connect();
        iolib::job_finishing_sequence($dbh,$Server_epilogue,$Server_hostname,$Server_port,$j->{job_id},\@events);
        iolib::disconnect($dbh);
        exit(0);
    }
}
iolib::unlock_table($base);

iolib::disconnect($base);

exit($Exit_code);