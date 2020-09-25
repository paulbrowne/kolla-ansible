#!/bin/bash

# Test deployment of magnum and octavia.

set -o xtrace
set -o errexit

# Enable unbuffered output for Ansible in Jenkins.
export PYTHONUNBUFFERED=1


function test_magnum_clusters {
    openstack coe cluster list
    openstack coe cluster template list
}

function register_amphora_image {
    amphora_url=https://tarballs.opendev.org/openstack/octavia/test-images/test-only-amphora-x64-haproxy-ubuntu-bionic.qcow2
    curl -o amphora.qcow2 $amphora_url
    export OS_USERNAME=octavia
    export OS_PASSWORD=$(awk '$1 == "octavia_keystone_password:" { print $2 }' /etc/kolla/passwords.yml)
    export OS_PROJECT_NAME=service
    openstack image create amphora-x64-haproxy --file amphora.qcow2  --tag amphora --disk-format qcow2
    . /etc/kolla/admin-openrc.sh
}

function test_octavia {
    register_amphora_image

    # Smoke test.
    openstack loadbalancer list

    # Create a server to act as a backend.
    openstack server create --wait --image cirros --flavor m1.tiny --key-name mykey --network demo-net lb_member --wait
    member_fip=$(openstack floating ip create public1 -f value -c floating_ip_address)
    openstack server add floating ip lb_member ${member_fip}
    member_ip=$(openstack floating ip show ${member_fip} -f value -c fixed_ip_address)

    # Dummy HTTP server.
    attempts=12
    for i in $(seq 1 ${attempts}); do
        if ssh -v -o BatchMode=yes -o StrictHostKeyChecking=no cirros@${member_fip} 'nohup sh -c "while true; do echo -e \"HTTP/1.1 200 OK\n\n $(date)\" | sudo nc -l -p 8000; done &"'; then
            break
        elif [[ $i -eq ${attempts} ]]; then
            echo "Failed to access server via SSH after ${attempts} attempts"
            echo "Console log:"
            openstack console log show lb_member
            return 1
        else
            echo "Cannot access server - retrying"
        fi
        sleep 10
    done

    # Create a load balancer.
    openstack loadbalancer create --name lb --vip-subnet-id demo-subnet --wait
    openstack loadbalancer listener create --name listener --protocol HTTP --protocol-port 8000 --wait lb
    openstack loadbalancer pool create --name pool --lb-algorithm ROUND_ROBIN --listener listener --protocol HTTP --wait
    openstack loadbalancer member create --subnet-id demo-subnet --address ${member_ip} --protocol-port 8000 pool --wait

    # Add a floating IP to the load balancer.
    lb_fip=$(openstack floating ip create public1 -f value -c name)
    lb_vip=$(openstack loadbalancer show lb -f value -c vip_address)
    lb_port_id=$(openstack port list --fixed-ip ip-address=$lb_vip -f value -c ID)
    openstack floating ip set $lb_fip --port $lb_port_id

    # Attempt to access the load balanced HTTP server.
    attempts=12
    for i in $(seq 1 ${attempts}); do
        if curl $lb_fip:8000; then
            break
        elif [[ $i -eq ${attempts} ]]; then
            echo "Failed to access load balanced service after ${attempts} attempts"
            return 1
        else
            echo "Cannot access load balancer - retrying"
        fi
        sleep 10
    done

    # Clean up.
    openstack loadbalancer delete lb --cascade --wait
    openstack floating ip delete ${lb_fip}

    openstack server remove floating ip lb_member ${member_fip}
    openstack floating ip delete ${member_fip}
    openstack server delete --wait lb_member
}

function test_magnum_logged {
    . /etc/kolla/admin-openrc.sh
    . ~/openstackclient-venv/bin/activate
    test_magnum_clusters
    test_octavia
}

function test_magnum {
    echo "Testing Magnum and Octavia"
    test_magnum_logged > /tmp/logs/ansible/test-magnum 2>&1
    result=$?
    if [[ $result != 0 ]]; then
        echo "Testing Magnum and Octavia failed. See ansible/test-magnum for details"
    else
        echo "Successfully tested Magnum and Octavia. See ansible/test-magnum for details"
    fi
    return $result
}

test_magnum
