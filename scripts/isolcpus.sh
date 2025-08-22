#!/bin/bash

# Resturn the ID of the largest NUMA Node
get_largest_numa_id () {
    NUMA_NODES=$(lscpu --all --extended -J | jq -r '.cpus[].node')
    printf '%s\n' "${NUMA_NODES[@]}" | sort | uniq -c | sort -k1,1nr -k2 | awk '{print $2; exit}'
}

# Return the numa NODE with more CPUs
get_cpus_in_largest_numa () {
    NUMA_NODES=$(lscpu --all --extended -J | jq -r '.cpus[].node')
    printf '%s\n' "${NUMA_NODES[@]}" | sort | uniq -c | sort -k1,1nr -k2 | awk '{print $1; exit}'
}

get_cpu_list () {
    CPU_LIST=$(lscpu --all --extended -J | jq -r '.cpus[] | select(.node=='\"$1\"').cpu' | head -n $2)

    echo "$CPU_LIST" | paste -sd "," -
}

min() {
    printf "%s\n" "$@" | sort -g | head -n1
}

if [ "$#" -ne 1 ]; then
    echo "USE: $0 <Number of IsolCPUs>"
    exit 1
fi

# Installing dependencies
sudo apt install -y jq

echo "Isolating CPUs..."

NUM_NUMA_NODES=$(lscpu | grep "NUMA node(s):" | awk '{ print $3 }')

# We can isolate up to the number of CPUs in the largest NUMA Node
CPUS_IN_LARGEST_NUMA=$(get_cpus_in_largest_numa)
if [ $NUM_NUMA_NODES == 1 ]; then
    # If there is only one NUMA node, we can isolate all but one CPUs
    CPUS_IN_LARGEST_NUMA=$((CPUS_IN_LARGEST_NUMA - 1))
fi
CPUS=$(min $1 $CPUS_IN_LARGEST_NUMA)
LARGEST_NUMA=$(get_largest_numa_id)
echo "Num. of CPUs to isolate: $CPUS"
ISOL_CPUS=$(get_cpu_list $LARGEST_NUMA $CPUS)
echo "IsolCPUs: $ISOL_CPUS"
echo 'GRUB_CMDLINE_LINUX="$GRUB_CMDLINE_LINUX isolcpus='$ISOL_CPUS'"' | sudo tee -a /etc/default/grub > /dev/null

sudo update-grub

echo "CPUs ($ISOL_CPUS) isolated!"