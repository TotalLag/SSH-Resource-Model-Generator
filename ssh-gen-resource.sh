#!/bin/bash
# Requires: mktemp
#
# DESCRIPTION
#  Takes a set of newline delimited hosts and runs a remote
#  script to collect host metadata to generate resources.xml document. 
#


die() { echo $* 1>&2 ; exit 1 ; }

PROG=`basename $0`
WORKSPACE=$(mktemp -d /tmp/${PROG}.XXXX) || die
SSH_ARGS=

# Option defaults
SSH_USER=$(whoami)
VERBOSE=0
NODE_SCRIPT=
HOST_FILE=
SSHID_FILE=
usage()
{
cat <<EOF
usage: $PROG options 

OPTIONS:
  -h  Show this message
  -i  identify file (default reads current user)
  -f  hosts file (default reads stdin)
  -s  script file (default uses internal)
  -u  Remote SSH username (default=$SSH_USER)
EOF
}

while getopts "hvu:i:f:s:" OPTION
do
    case $OPTION in
    h)
        usage
        exit 1
        ;;
    v)
        VERBOSE=1
        ;;
    u)
        SSH_USER=$OPTARG
        ;;
    i)
        SSHID_FILE="-i ${OPTARG}"
        ;;
    f)
        HOST_FILE=$OPTARG
        ;;
    s)
        NODE_SCRIPT=$OPTARG
        ;;
    *)
        usage
        exit 1
    esac
done

verbose() { [ "$VERBOSE" == "1" ] && { echo "VERBOSE : $*" 1>&2 ; } }

[ -s "$HOST_FILE" -a ! -r "$HOST_FILE" ] && {
    die "file not readable: $HOST_FILE"
}
[ -s "$SSHID_FILE" -a ! -r "$SSHID_FILE" ] && {
    die "file not readable: $SSHID_FILE"
} || {
    SSH_ARGS="$SSH_ARGS $SSHID_FILE"
}

mkdir -p ${WORKSPACE} || { die "Failed creating data directory: $WORKSPACE" ; }

if [ -z "${NODE_SCRIPT}" ] 
then
NODE_SCRIPT=`mktemp ${WORKSPACE}/node-collect.XXXX`
# here doc generates collection script template
cat > ${NODE_SCRIPT} <<EOF
#!/bin/bash
USAGE="\$0 <outputfile>"
[ \$# = 1 ] || { echo "\$USAGE" ; exit 1 ; }
outputfile=\$1
# metadata about the Node
hostname=\$(hostname)
osArch=\$(uname -p)
osVers=\$(lsb_release -d | cut -d: -f2 | sed s/'^\t'//)
osName=\$(lsb_release -c | cut -d: -f2 | sed s/'^\t'//)
osFamily=\$(uname | tr "[:upper:]" "[:lower:]")
osKernel=\$(uname -r)
username=\$(whoami)
dstamp=\$(date "+%Y-%m-%d %H:%M:%S")
tags=\$(lsb_release -i | cut -d: -f2 | sed s/'^\t'//)
# print out the xml element
# <node name="<server name>" description="Rundeck server node" tags="" hostname="<server name>" osArch="amd64" osFamily="unix" osName="Linux" osVersion="3.2.0-24-virtual" username="root"/>
echo "  <node name='\${hostname}' description='Last updated \${dstamp}' tags='\${tags}' hostname='\${hostname}' osArch='\${osArch}' \
osFamily='\${osFamily}' osName='\${osName}' osVersion='\${osVers}' Kernel='\${osKernel}' username='\${username}'/>" > \$outputfile
EOF
fi

# Reasign fd0 to the specified host file
[ -f "$HOST_FILE" ] && { exec 0<> $HOST_FILE ; }

verbose "{SSH_USER=\"$SSH_USER\", WORKSPACE=\"$WORKSPACE\", HOST_FILE=\"$HOST_FILE\", SSH_ARGS=\"$SSH_ARGS\"}"

numProcessed=0
while read line
do
    echo $line | egrep -q '^#' && continue ;#skip comment lines
    hostinfo=( $line )                     ;#parse the line into an array
    [ ${#hostinfo[*]} -lt 1 ]  && continue ;#skip lines with no info
    host=${hostinfo[0]}
    verbose "collecting node info from host: ${host} ..."
    scp $SSH_ARGS $NODE_SCRIPT ${SSH_USER}@${host}:/tmp/$(basename $NODE_SCRIPT) || {
    	die "Failed copying collection script on host: ${host}"
    }
    ssh $SSH_ARGS -n ${SSH_USER}@${host} sh /tmp/$(basename $NODE_SCRIPT) /tmp/node.xml.$$ || {
        die "Failed executing collection script on host: ${host}"
    }
    scp $SSH_ARGS ${SSH_USER}@${host}:/tmp/node.xml.$$ ${WORKSPACE}/${host}.xml || {
        die "Failed copying resources data from host: ${host}"
    }
    numProcessed=$(expr "$numProcessed" + 1)
done 

if [ "$numProcessed" -gt 0 ]
then
    verbose "Generating resources.xml for $i hosts ..."
    echo "<project>" 
    cat ${WORKSPACE}/*.xml || die "Failure due to internal script error"
    echo "</project>"
    verbose "Done."
fi

#
# clean up the temporary files
#
verbose "cleaning up temporary files"
rm -rf ${WORKSPACE}