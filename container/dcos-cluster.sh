#!/bin/bash

if [ $# -lt 3 ]; then
  echo "Usage $0 <num-slaves> <hostip> <port-range> <cluster-base-dir>"
  exit 99
fi

NUM_SLAVES=$1
HOSTIP=$2
PORT_RANGE=$3
# strip any trailing slashes. this is actually needed. mesos ui will not be able to access the files otherwise :S
CLUSTER_BASE_DIR=$(echo $4 | sed -e 's/\/*$//g')

mountpoint $CLUSTER_BASE_DIR > /dev/null

if [ "$?" != "0" ]; then
  echo "$CLUSTER_BASE_DIR is not mounted"
  exit 98
fi

HOSTNAME=`hostname`
CLUSTER_WORK_DIR=$CLUSTER_BASE_DIR/$HOSTNAME
IP=$(hostname --ip-address)

mv /usr/bin/docker /usr/bin/docker-real
cat << EOF >/usr/bin/docker
#!/bin/sh
HOSTNET=0
IS_NET=0
for var in "\$@"; do
  if [ "\$var" = "--net=host" ]; then
    HOSTNET=1
  fi

  if [ "\$var" = "--net" ];then
    IS_NET=1
  else
    if [ "\$IS_NET" -eq "1" ] && [ "\$var" = "host" ];then
      HOSTNET=1
    fi
    IS_NET=0
  fi
done

if [ "\$1" = "-H" ] && [ "\$3" = "run" ]; then
  DOCKER_ENDPOINT=\$2
  
  shift
  shift
  shift
  set -- /usr/bin/docker-real -H \$DOCKER_ENDPOINT run --dns=$IP "\$@"
else
  set -- /usr/bin/docker-real "\$@"
fi
exec "\$@"
EOF
chmod +x /usr/bin/docker

/etc/init.d/zookeeper start

let master_port=5050

mkdir -p "$CLUSTER_WORK_DIR"/mesos-master || exit 1

cat << EOF >/etc/supervisor/conf.d/mesos-master.conf
[program:mesos-master]
command=mesos-master --no-hostname_lookup --zk=zk://$IP:2181/mesos --port=5050 --quorum=1 --registry=in_memory --work_dir=$CLUSTER_WORK_DIR/mesos-master
EOF

cat << EOF >/etc/supervisor/conf.d/marathon.conf
[program:marathon]
command=marathon --master zk://$IP:2181/mesos --zk zk://$IP:2181/marathon --logging_level warn
EOF


ls -al /
/distribute-slave-resources $1 $CLUSTER_BASE_DIR/$HOSTNAME > /tmp/base_resources.json
cat /tmp/base_resources.json
cat /tmp/base_resources.json | jq .

let slave_start_port=${PORT_RANGE%:*}
let slave_end_port=${PORT_RANGE#*:}
let num_ports=(slave_end_port-slave_start_port)/NUM_SLAVES

for i in `seq $NUM_SLAVES`; do
  SLAVE_DIR=$CLUSTER_WORK_DIR/mesos-slave-"$i"
  mkdir -p $SLAVE_DIR
  let slave_resource_start_port=slave_start_port+1
  let slave_resource_end_port=slave_start_port+num_ports-1

  iptables -t nat -A PREROUTING -p tcp -d $IP --dport $slave_resource_start_port:$slave_resource_end_port -j DNAT --to-destination $HOSTIP
  iptables -t nat -A OUTPUT -p tcp -d $IP --dport $slave_resource_start_port:$slave_resource_end_port -j DNAT --to-destination $HOSTIP
  
  mkdir -p /mount-slave-$i
  mkdir -p /disk-slave-$i
  mount --bind /disk-slave-$i /mount-slave-$i
  # end seems to be a reserved keyword :D
  cat /tmp/base_resources.json | jq --arg path /mount-slave-$i --argjson start $slave_resource_start_port --argjson ende $slave_resource_end_port '.+=[{"name": "ports", "type": "RANGES", "ranges": {"range": [{"begin": $start,"end": $ende}]}},{"name" : "disk", "type" : "SCALAR", "role": "*", "scalar" : { "value" : 4096 }, "disk" : {"source" : {"type" : "MOUNT", "mount" : { "root" : $path }}}}]' > /tmp/slave-resources-$i.json
  cat /tmp/slave-resources-$i.json
  cat << EOF >/etc/supervisor/conf.d/mesos-slave-"$i".conf
[program:mesos-slave-$i]
command=mesos-slave --no-hostname_lookup --master=zk://$IP:2181/mesos --containerizers=docker --port=$slave_start_port --work_dir=$SLAVE_DIR --no-systemd_enable_support --resources=file:///tmp/slave-resources-$i.json
EOF
  let slave_start_port=slave_start_port+num_ports
done
# XXX don't get it :S i am unable to limit that on our portrange...it's been too long
iptables -t nat -A POSTROUTING  -j MASQUERADE

cat << EOF >/stop.sh
#!/bin/sh
supervisorctl shutdown
for i in $CLUSTER_WORK_DIR/mesos-slave-*/meta/slaves/latest; do
  SLAVE_NAME=\$(readlink \$i | xargs basename)
  docker rm -f -v \$(docker ps | grep \$SLAVE_NAME | cut -f1 -d " ") &> /dev/null &
done
rm -rf $CLUSTER_WORK_DIR &
wait
exit 0
EOF
chmod +x /stop.sh

supervisord -c /etc/supervisor/supervisord.conf

trap '/bin/bash /stop.sh && exit 0' SIGINT SIGTERM
tail -f /var/log/supervisor/* &
wait
