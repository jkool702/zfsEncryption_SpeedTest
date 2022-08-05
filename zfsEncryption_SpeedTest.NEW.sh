#!/bin/bash

# run this as root
! [[ "${USER}" == 'root' ]] && echo "please run this script as root" >&2 && return 1

timeStart="$(date +%s)"

# set customizeable parameters

# blockSizeKB is an array of positive integers specifying the differend block sizes (in KB) to use with fio
# rwMixPrct is an array of integers between 0-100 specifying the % read in the IO mix. % write is $((( 100 - $rwMixPrct[$kk] )))
# devSizeMB is the size of the ramdisk (in MB) that will serve as the zfs storage backend. Note that there will be 4 images of this size created. Default is to use 1/8 of RAM per image --> 1/2 RAM total. 
# fioSizeMB is trhe size (in MB) of the file on the zfs dataset that fio uses. default is 3/4 of devSizeMB for blocksizes >= zfs record size. For smaller block sizes this value is reduced proportionally to avoid very long run times.
# nParallel_fio is a positive integer, that describes how many parallel runs the fio command uses. The sum of the sizes of all runs equalos $fioSizeMB
# zpoolCreateOpts list the flags to use when creating the temporary ZFS pools
# localMode=1 runs the FIO benchmarks for the selected test types using loop devices loop devices for files that are on local storage instead of on a tmpfs
# testTypes is an array listing which benchmarks to run
#     TMPFS --> on a tmpfs (no ZFS)
#     BASE --> on standard (unencrypted) ZFS
#     ZFS --> on ZFS with native ZFS encryption
#     LUKS --> on standard ZFS on top of a LUKS encrypted device
#     LUKS_ZFS --> on ZFS with native encryption on top of a LUKS encrypted device (double encrypted)

# Note: the bottom level block device used by the `zpool create` or `cryptsetup luksFormat` command can be made 2 possible ways, depending if kernel module "brd" is already in use`
#       if the brd kernel module is not already in use and localMode=0; the brd kernel module (which creates /dev/ramX block devices) is used for all tests except type TMPFS
#       if the brd kernel module is already in use, then a tmpfs is mounted, a file with alll 0's (filled with dd) is added to it, and a loop device (/dev/loopX) using that file 

#blockSizeKB=(1024 512 256 128 64 32 16 8 4 2 1)
#rwMixPrct=(0 20 50 80 100)
#nParallel_fio=$((( $(nproc) / 2 )))
#testTypes=(TMPFS BASE ZFS LUKS LUKS_ZFS)

blockSizeKB=(128 4)
rwMixPrct=(0 50 100)
devSizeMB=$((( $(cat /proc/meminfo | grep MemTotal | awk '{print $2}') / 4096 )))
nParallel_fio=2
fioSizeMB=$((( ( 3 * ${devSizeMB} ) / ( 4 * ${nParallel_fio} ) )))

zpoolCreateOpts='-o ashift=12 -o cachefile=none -o failmode=continue -O mountpoint=none -O atime=off -O checksum=sha256 -O compression=lz4 -O dedup=off -O defcontext=none -O dnodesize=auto -O exec=on -O logbias=throughput -O overlay=on -O primarycache=all -O readonly=off -O redundant_metadata=all -O relatime=off -O rootcontext=none -O secondarycache=none -O sync=standard -O volmode=full -O xattr=sa'

testTypes=(BASE ZFS LUKS)

localMode=0

# make text formatting later on look nice

declare -A testNames
testNames[TMPFS]='TMPFS' 
testNames[BASE]='ZFS (no encryption)' 
testNames[ZFS]='ZFS (native encryption)' 
testNames[LUKS]='ZFS (LUKS encryption)' 
testNames[LUKS_ZFS]='ZFS (LUKS+native encryption)'
testNames[BLOCKSIZE]='Block Size (KB)'

maxNameLength=0
for kk in "${!testNames[@]}"; do
	(( ${#testNames[$kk]} > ${maxNameLength} )) && maxNameLength=${#testNames[$kk]}
done

for kk in "${!testNames[@]}"; do
	testNames[$kk]="${testNames[$kk]}$(ll=0; while (( ${ll} < ( ${maxNameLength} - ${#testNames[$kk]} ) )); do echo -n ' '; ((ll++)); done):"
done

blockSizeStr=("${blockSizeKB[@]}")
for kk in 1 2 3; do 
	blockSizeStr[$kk]=" ${blockSizeStr[$kk]}"
done
for kk in 4 5 6; do 
	blockSizeStr[$kk]="  ${blockSizeStr[$kk]}"
done
for kk in 7 8 9 10; do 
	blockSizeStr[$kk]="   ${blockSizeStr[$kk]}"
done

# move old results

if [[ -d ./zfsEncryption_SpeedTest_results ]]; then
	mkdir -p ./zfsEncryption_SpeedTest_results/old
	\mv -f ./zfsEncryption_SpeedTest_results/* ./zfsEncryption_SpeedTest_results/old 2>/dev/null
fi

mkdir -p ./zfsEncryption_SpeedTest_results

if lsmod | grep -q brd || (( ${localMode} == 1 )); then
	brdFlag=0
else
	brdFlag=$(printf '%s\n' "${testTypes[@]}" | grep -vE '^TMPFS$' | wc -l)
fi

# install fio 
# this command is Fedora-specific....install on other distros will vary

{ [[ -f /bin/rpm ]] && [[ -f /bin/dnf ]]; } && rpm -qa | grep -q fio || dnf install fio

# BEGHIN MAIN LOOP OVER TEST CASES

unset devALL
unset resultsALL
declare -A devALL
declare -A resultsALL

for nn in "${testTypes[@]}"; do

	# setup tmpfs-->loop or brd-based ramdisk block device for current test type

	echo "BEGINNING SETUP FOR ${nn}" >&2	

	# brd ramdisk setup
	if (( ${brdFlag} > 0 )) && [[ "${nn}" != 'TMPFS' ]]; then
		echo "SETTING UP RAMDISK USING BRD" >&2
		
		modprobe brd rd_nr=1 rd_size=$((( ${devSizeMB} * 1024 )))
		
		devALL["${nn}$( [[ "${nn}" == LUKS* ]] && echo '0' )"]="/dev/ram0"
	fi

	# always mount a tmpfs unless [[ localMode == 1 ]]. If using brd ramdisk it goes mostly unused.
	mkdir -p "/mnt/test${nn}"
	cat /proc/mounts | grep -q "/mnt/test${nn}" && umount "/mnt/test${nn}"
	(( ${localMode} == 0 )) && mount -t tmpfs tmpfs "/mnt/test${nn}"
	mkdir -p "/mnt/test${nn}/mount"


	if [[ "${nn}" != 'TMPFS' ]]; then
		
		# create tmpfs-backed zerod file for loop device
		(( ${brdFlag} == 0 )) && dd if=/dev/zero of=/mnt/test${nn}/file${nn}.img bs=1M count="${devSizeMB}"
		
		# generate keyfiles
		[[ "${nn}" == *ZFS ]] && openssl rand -out /mnt/test${nn}/keyZFS 32
		[[ "${nn}" == LUKS* ]] && openssl rand -out /mnt/test${nn}/keyLUKS 64
	
		# setup loop device	
		(( ${brdFlag} == 0 )) && devALL["${nn}$( [[ "${nn}" == LUKS* ]] && echo '0' )"]="$(losetup --show -v -f /mnt/test${nn}/file${nn}.img)"

		if [[ "${nn}" == LUKS* ]]; then

			# setup cryptsetup for LUKS options
			cryptsetup luksFormat "${devALL["${nn}0"]}" /mnt/test${nn}/keyLUKS -q --type luks2 --hash sha256 --cipher aes-xts-plain64 --key-size 512 --use-random --sector-size 4096 --label crypt${nn}
			cryptsetup open --type luks2 "${devALL["${nn}0"]}" --allow-discards --perf-no_read_workqueue --perf-no_write_workqueue crypt${nn} --key-file=/mnt/test${nn}/keyLUKS
			
			devALL["${nn}"]="/dev/disk/by-id/dm-uuid-CRYPT-LUKS2-$(cryptsetup luksUUID "${devALL["${nn}0"]}" | tr -d '-')-crypt${nn}"
		fi
		
		# setup ZFS pool and dataset
		zpool create ${zpoolCreateOpts} "pool${nn}" "${devALL["${nn}"]}"
		zfs create -o mountpoint=/mnt/test${nn}/mount $( [[ "${nn}" == *ZFS ]] && echo "-o encryption=aes-256-gcm -o keyformat=raw -o keylocation=file:///mnt/test${nn}/keyZFS" ) pool${nn}/ROOT

	fi

	echo "SETUP FOR ${nn} COMPLETED" >&2

	echo "BEGINNING FIO TESTING FOR ${nn}" >&2

	# begin benchmarking for current test type

	for rwP in "${rwMixPrct[@]}"; do

		for bsKB in "${blockSizeKB[@]}"; do

			# for small (sub-recordsize) fio blocksizes reduce test size. Otherwise the tests take forever, due to fio read/write amplification
			reduceFactor=$((( 128 / ${bsKB} )))
			(( ${reduceFactor} == 0 )) && reduceFactor=1

			echo -e "\n\nTESTING -- BLOCK SIZE = ${bsKB}K \n\n" >> "/mnt/test${nn}/fio_results_rw${rwP}_test${nn}"

			# run fio benchmark		
			fio --randrepeat=1 --numjobs=${nParallel_fio} --group_reporting --ioengine=libaio --gtod_reduce=1 --name="test${nn}" --directory="/mnt/test${nn}/mount" --bs="${bsKB}k" --iodepth=64 --size="$((( ${fioSizeMB} / ${reduceFactor} )))M" --unified_rw_reporting=both --readwrite=randrw --rwmixread="${rwP}" --max-jobs="$(nproc)" | tee -a "/mnt/test${nn}/fio_results_rw${rwP}_test${nn}"
	
			# remove fio file, so that each fio benchmark starts with nothing to put them all on "equal ground"
			rm -f /mnt/test${nn}/mount/* 
		done

		# copy results to persistent storage

		\cp -f "/mnt/test${nn}/fio_results_rw${rwP}_test${nn}" ./zfsEncryption_SpeedTest_results
	
		# group results into bash associative arrays
		for ioType in read write mixed; do
			resultsALL["test${nn}_rw${rwP}_${ioType}"]="$(echo $(cat "/mnt/test${nn}/fio_results_rw${rwP}_test${nn}" | grep "${ioType}:" | sed -E s/'^.*\:([^\(]*).*$'/'\1'/ | awk -F ',' '{print $2}' | sed -E s/'^.*='//) | sed -E s/' '/'\t'/g)"
			resultsALL["test${nn}_rw${rwP}_${ioType}_IOPS"]="$(echo $(cat "/mnt/test${nn}/fio_results_rw${rwP}_test${nn}" | grep "${ioType}:" | sed -E s/'^.*\:([^\(]*).*$'/'\1'/ | awk -F ',' '{print $1}' | sed -E s/'^.*='//) | sed -E s/' '/'\t'/g)"
		done

	done

	echo "FIO TESTING FOR ${nn} COMPLETED" >&2

	echo -n "CLEANING UP ${nn}..." >&2

	# clean up


	if [[ "${nn}" != 'TMPFS' ]]; then
		# umount ZFS datasets
		zfs umount "pool${nn}/ROOT"

		# destroy ZFS pools
		zpool destroy "pool${nn}"

		# close LUKS device (if applicable) and detach loop devices
		if [[ "${nn}" == LUKS* ]]; then
			cryptsetup close "${devALL["${nn}"]}"
			cryptsetup close "crypt${nn}"
			(( ${brdFlag} == 0 )) && losetup -d "${devALL["${nn}0"]}"
		else
			(( ${brdFlag} == 0 )) && losetup -d "${devALL["${nn}"]}"
		fi
	fi

	# make sure any fio remnants are gone
	rm -rf "/mnt/test${nn}/mount"

	# umount tmpfs ramdisk
	{ (( ${localMode} == 0 )) || [[ "${nn}" == 'TMPFS' ]]; } && umount "/mnt/test${nn}"

	# unload brd kmod --> destroy brd ramdisk and removes /dev/ram0
	(( ${brdFlag} == 1 )) && [[ "${nn}" != 'TMPFS' ]] && modprobe -r brd 
		
	echo "DONE" >&2

	sleep 1

done

sleep 1
sync


# generate summary report and save to ./zfsEncryption_SpeedTest_results/ALL_RESULTS_SUMMARY

for rwP in "${rwMixPrct[@]}"; do
	echo -e "\n----------------------------------------------------------------\n||---- RESULT SUMMARY FOR A ${rwP}% READ / $((( 100 - ${rwP} )))% WRITE WORKLOAD ----||\n----------------------------------------------------------------\n"| tee -a ./zfsEncryption_SpeedTest_results/ALL_RESULTS_SUMMARY

	for ioType in read write mixed read_IOPS write_IOPS mixed_IOPS; do
	
		(( ${rwP} == 0 )) && echo "${ioType}" | grep -qE '((read)|(mixed))(IOPS)?' && continue
		(( ${rwP} == 100 )) && echo "${ioType}" | grep -qE '((write)|(mixed))(IOPS)?' && continue

		echo -e "${ioType^^} \n" | sed -E s/'_IOPS'/' (IOPS)'/ | tee -a ./zfsEncryption_SpeedTest_results/ALL_RESULTS_SUMMARY
		echo -n -e "${testNames[BLOCKSIZE]}" | tee -a ./zfsEncryption_SpeedTest_results/ALL_RESULTS_SUMMARY
		printf '%s'"$([[ "${ioType}" == *IOPS ]] && echo '    ')"'\t' "${blockSizeStr[@]}" | tee -a ./zfsEncryption_SpeedTest_results/ALL_RESULTS_SUMMARY
		echo "" | tee -a ./zfsEncryption_SpeedTest_results/ALL_RESULTS_SUMMARY

		for nn in "${testTypes[@]}"; do
			echo -n -e "${testNames["${nn}"]}" | tee -a ./zfsEncryption_SpeedTest_results/ALL_RESULTS_SUMMARY
			echo "${resultsALL["test${nn}_rw${rwP}_${ioType}"]}" | tee -a ./zfsEncryption_SpeedTest_results/ALL_RESULTS_SUMMARY
		done

		echo -e "\n\n----------------------------------------------------------------\n----------------------------------------------------------------\n" | tee -a ./zfsEncryption_SpeedTest_results/ALL_RESULTS_SUMMARY
	done
done

# make sure brd kmod is unloaded 
modprobe -r brd

# print how long the code took to run
timeEnd="$(date +%s)"
timeElapsed="$((( ${timeEnd} - ${timeStart} )))"

echo "This ZFS Encryption Speed Test took ${timeElapsed} Seconds" >&2
