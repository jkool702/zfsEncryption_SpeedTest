#!/usr/bin/bash +x

# run this as root
! [[ "${USER}" == 'root' ]] && echo "please run this script as root" >&2 && return 1

timeStart="$(date +%s)"

# optional: customize parameters

# blockSizeKB is an array of positive integers specifying the differend block sizes (in KB) to use with fio
# rwMixPrct is an array of integers between 0-100 specifying the % read in the IO mix. % write is $((( 100 - $rwMixPrct[$kk] )))
# devSizeMB is the size of the ramdisk (in MB) that will serve as the zfs storage backend. Note that there will be 4 images of this size created. Default is to use 1/8 of RAM per image --> 1/2 RAM total. 
# fioSizeMB is trhe size (in MB) of the file on the zfs dataset that fio uses. default is 3/4 of devSizeMB for blocksizes >= zfs record size. For smaller block sizes this value is reduced proportionally to avoid very long run times.

blockSizeKB=(1024 512 256 128 64 32 16 8 4 2 1)
rwMixPrct=(0 20 50 80 100)
devSizeMB=$((( $(cat /proc/meminfo | grep MemTotal | awk '{print $2}') / 8192 )))
fioSizeMB=$((( ( ${devSizeMB} * 3 ) / 4 )))

# make text formatting later on look nice

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

# mount tmpfs filesystems

for nn in testTMPFS testBASE testZFS testLUKS; do
	mkdir -p "/mnt/${nn}"
	cat /proc/mounts | grep -q "/mnt/${nn}" && umount "/mnt/${nn}"
	mount -t tmpfs tmpfs "/mnt/${nn}"
	mkdir -p "/mnt/${nn}/mount"
done

# create RAM-backed loop devices

dd if=/dev/zero of=/mnt/testBASE/fileBASE.img bs=1M count="${devSizeMB}"
dd if=/dev/zero of=/mnt/testZFS/fileZFS.img bs=1M count="${devSizeMB}"
dd if=/dev/zero of=/mnt/testLUKS/fileLUKS.img bs=1M count="${devSizeMB}"

devBASE="$(losetup --show -v -f /mnt/testBASE/fileBASE.img)"
devZFS="$(losetup --show -v -f /mnt/testZFS/fileZFS.img)"
devLUKS="$(losetup --show -v -f /mnt/testLUKS/fileLUKS.img)"

# generate keyfiles

openssl rand -out /mnt/testZFS/key 32
openssl rand -out /mnt/testLUKS/key 64

# setup "zfs baseline" case (zfs, no encryption)

zpool create -o ashift=12 -o cachefile=none -o failmode=continue -O mountpoint=none -O aclinherit=passthrough-x -O acltype=posixacl -O atime=on -O checksum=sha256 -O compression=lz4 -O dedup=off -O defcontext=none -O dnodesize=auto -O exec=on -O logbias=latency -O overlay=on -O primarycache=all -O readonly=off -O redundant_metadata=all -O relatime=on -O rootcontext=none -O secondarycache=none -O sync=standard -O volmode=full -O xattr=sa poolBASE "${devBASE}"

zfs create -o mountpoint=/mnt/testBASE/mount poolBASE/ROOT

# setup "zfs native encryption" case

zpool create -o ashift=12 -o cachefile=none -o failmode=continue -O mountpoint=none -O aclinherit=passthrough-x -O acltype=posixacl -O atime=on -O checksum=sha256 -O compression=lz4 -O dedup=off -O defcontext=none -O dnodesize=auto -O exec=on -O logbias=latency -O overlay=on -O primarycache=all -O readonly=off -O redundant_metadata=all -O relatime=on -O rootcontext=none -O secondarycache=none -O sync=standard -O volmode=full -O xattr=sa poolZFS "${devZFS}"

zfs create -o mountpoint=/mnt/testZFS/mount -o encryption=aes-256-gcm -o keyformat=raw -o keylocation=file:///mnt/testZFS/key poolZFS/ROOT

# setup "zfs over LUKS" case (hash=sha256, cipher=aes-xts keysize=512)

cryptsetup luksFormat "${devLUKS}" /mnt/testLUKS/key -q --type luks2 --hash sha256 --cipher aes-xts-plain64 --key-size 512 --use-random --sector-size 4096 --label cryptLUKS
cryptsetup open --type luks2 "${devLUKS}" cryptLUKS --key-file=/mnt/testLUKS/key

devLUKS_crypt="/dev/disk/by-id/dm-uuid-CRYPT-LUKS2-$(cryptsetup luksUUID "${devLUKS}" | tr -d '-')-cryptLUKS"

zpool create -o ashift=12 -o cachefile=none -o failmode=continue -O mountpoint=none -O aclinherit=passthrough-x -O acltype=posixacl -O atime=on -O checksum=sha256 -O compression=lz4 -O dedup=off -O defcontext=none -O dnodesize=auto -O exec=on -O logbias=latency -O overlay=on -O primarycache=all -O readonly=off -O redundant_metadata=all -O relatime=on -O rootcontext=none -O secondarycache=none -O sync=standard -O volmode=full -O xattr=sa poolLUKS "${devLUKS_crypt}"

zfs create -o mountpoint=/mnt/testLUKS/mount poolLUKS/ROOT

# install fio 
# this command is Fedora-specific....install on other distros will vary

rpm -qa | grep -q fio || dnf install fio

# run fio tests for the 4 test datasets -- loop over test cases

for rwP in "${rwMixPrct[@]}"; do

	for bsKB in "${blockSizeKB[@]}"; do

		reduceFactor=$((( 128 / ${bsKB} )))
		(( ${reduceFactor} == 0 )) && reduceFactor=1

		for rootDir in /mnt/testTMPFS /mnt/testBASE /mnt/testZFS /mnt/testLUKS; do

			echo -e "\n\nTESTING -- BLOCK SIZE = ${bsKB}K \n\n" >> "${rootDir}/fio_results_rw${rwP}_${rootDir##*/}"
		
			fio --randrepeat=1 --ioengine=libaio --gtod_reduce=1 --name="${rootDir##*/}" --directory="${rootDir}/mount" --bs="${bsKB}k" --iodepth=64 --size="$((( ${fioSizeMB} / ${reduceFactor} )))M" --readwrite=randrw --rwmixread="${rwP}" --max-jobs="$(nproc)" | tee -a "${rootDir}/fio_results_rw${rwP}_${rootDir##*/}"
	
		done
		rm -f /mnt/testTMPFS/mount/* /mnt/testBASE/mount/* /mnt/testZFS/mount/* /mnt/testLUKS/mount/*
	done

	# copy out result files

	mkdir -p ./zfsEncryption_SpeedTest_results
	\cp -f /mnt/test{TMPFS,BASE,ZFS,LUKS}/fio_results_rw${rwP}_* ./zfsEncryption_SpeedTest_results
	
	# group results into bash arrays
	
	mapfile -t testTMPFS_read < <(cat "/mnt/testTMPFS/fio_results_rw${rwP}_testTMPFS" | grep 'read:' | sed -E s/'^.*\:([^\(]*).*$'/'\1'/ | awk -F ',' '{print $2}' | sed -E s/'^.*='//)
	mapfile -t testTMPFS_read_IOPS < <(cat "/mnt/testTMPFS/fio_results_rw${rwP}_testTMPFS" | grep 'read:' | sed -E s/'^.*\:([^\(]*).*$'/'\1'/ | awk -F ',' '{print $1}' | sed -E s/'^.*='//)
	mapfile -t testTMPFS_write < <(cat "/mnt/testTMPFS/fio_results_rw${rwP}_testTMPFS" | grep 'write:' | sed -E s/'^.*\:([^\(]*).*$'/'\1'/ | awk -F ',' '{print $2}' | sed -E s/'^.*='//)
	mapfile -t testTMPFS_write_IOPS < <(cat "/mnt/testTMPFS/fio_results_rw${rwP}_testTMPFS" | grep 'write:' | sed -E s/'^.*\:([^\(]*).*$'/'\1'/ | awk -F ',' '{print $1}' | sed -E s/'^.*='//)
	
	mapfile -t testBASE_read < <(cat "/mnt/testBASE/fio_results_rw${rwP}_testBASE" | grep 'read:' | sed -E s/'^.*\:([^\(]*).*$'/'\1'/ | awk -F ',' '{print $2}' | sed -E s/'^.*='//)
	mapfile -t testBASE_read_IOPS < <(cat "/mnt/testBASE/fio_results_rw${rwP}_testBASE" | grep 'read:' | sed -E s/'^.*\:([^\(]*).*$'/'\1'/ | awk -F ',' '{print $1}' | sed -E s/'^.*='//)
	mapfile -t testBASE_write < <(cat "/mnt/testBASE/fio_results_rw${rwP}_testBASE" | grep 'write:' | sed -E s/'^.*\:([^\(]*).*$'/'\1'/ | awk -F ',' '{print $2}' | sed -E s/'^.*='//)
	mapfile -t testBASE_write_IOPS < <(cat "/mnt/testBASE/fio_results_rw${rwP}_testBASE" | grep 'write:' | sed -E s/'^.*\:([^\(]*).*$'/'\1'/ | awk -F ',' '{print $1}' | sed -E s/'^.*='//)
	
	mapfile -t testZFS_read < <(cat "/mnt/testZFS/fio_results_rw${rwP}_testZFS" | grep 'read:' | sed -E s/'^.*\:([^\(]*).*$'/'\1'/ | awk -F ',' '{print $2}' | sed -E s/'^.*='//)
	mapfile -t testZFS_read_IOPS < <(cat "/mnt/testZFS/fio_results_rw${rwP}_testZFS" | grep 'read:' | sed -E s/'^.*\:([^\(]*).*$'/'\1'/ | awk -F ',' '{print $1}' | sed -E s/'^.*='//)
	mapfile -t testZFS_write < <(cat "/mnt/testZFS/fio_results_rw${rwP}_testZFS" | grep 'write:' | sed -E s/'^.*\:([^\(]*).*$'/'\1'/ | awk -F ',' '{print $2}' | sed -E s/'^.*='//)
	mapfile -t testZFS_write_IOPS < <(cat "/mnt/testZFS/fio_results_rw${rwP}_testZFS" | grep 'write:' | sed -E s/'^.*\:([^\(]*).*$'/'\1'/ | awk -F ',' '{print $1}' | sed -E s/'^.*='//)
	
	mapfile -t testLUKS_read < <(cat "/mnt/testLUKS/fio_results_rw${rwP}_testLUKS" | grep 'read:' | sed -E s/'^.*\:([^\(]*).*$'/'\1'/ | awk -F ',' '{print $2}' | sed -E s/'^.*='//)
	mapfile -t testLUKS_read_IOPS < <(cat "/mnt/testLUKS/fio_results_rw${rwP}_testLUKS" | grep 'read:' | sed -E s/'^.*\:([^\(]*).*$'/'\1'/ | awk -F ',' '{print $1}' | sed -E s/'^.*='//)
	mapfile -t testLUKS_write < <(cat "/mnt/testLUKS/fio_results_rw${rwP}_testLUKS" | grep 'write:' | sed -E s/'^.*\:([^\(]*).*$'/'\1'/ | awk -F ',' '{print $2}' | sed -E s/'^.*='//)
	mapfile -t testLUKS_write_IOPS < <(cat "/mnt/testLUKS/fio_results_rw${rwP}_testLUKS" | grep 'write:' | sed -E s/'^.*\:([^\(]*).*$'/'\1'/ | awk -F ',' '{print $1}' | sed -E s/'^.*='//)
	
	# generate summary report
	
	echo -e "\n----------------------------------------------------------------\n||---- RESULT SUMMARY FOR A ${rwP}% READ / $((( 100 - ${rwP} )))% WRITE WORKLOAD ----||\n----------------------------------------------------------------\n"| tee -a ./zfsEncryption_SpeedTest_results/ALL_RESULTS_SUMMARY
	
	echo -e "READ -- DATA TRANSFER SPEEDS \n" | tee -a ./zfsEncryption_SpeedTest_results/ALL_RESULTS_SUMMARY
	echo -n -e "Block Size (KB):        \t" | tee -a ./zfsEncryption_SpeedTest_results/ALL_RESULTS_SUMMARY
	printf '%s     \t' "${blockSizeStr[@]}" | tee -a ./zfsEncryption_SpeedTest_results/ALL_RESULTS_SUMMARY
	echo "" | tee -a ./zfsEncryption_SpeedTest_results/ALL_RESULTS_SUMMARY
	echo -n -e "TMPFS:                  \t" | tee -a ./zfsEncryption_SpeedTest_results/ALL_RESULTS_SUMMARY
	printf '%s\t' "${testTMPFS_read[@]}" | tee -a ./zfsEncryption_SpeedTest_results/ALL_RESULTS_SUMMARY
	echo "" | tee -a ./zfsEncryption_SpeedTest_results/ALL_RESULTS_SUMMARY
	echo -n -e "ZFS (no encryption):    \t" | tee -a ./zfsEncryption_SpeedTest_results/ALL_RESULTS_SUMMARY
	printf '%s\t' "${testBASE_read[@]}" | tee -a ./zfsEncryption_SpeedTest_results/ALL_RESULTS_SUMMARY
	echo "" | tee -a ./zfsEncryption_SpeedTest_results/ALL_RESULTS_SUMMARY
	echo -n -e "ZFS (native encryption):\t" | tee -a ./zfsEncryption_SpeedTest_results/ALL_RESULTS_SUMMARY
	printf '%s\t' "${testZFS_read[@]}" | tee -a ./zfsEncryption_SpeedTest_results/ALL_RESULTS_SUMMARY
	echo "" | tee -a ./zfsEncryption_SpeedTest_results/ALL_RESULTS_SUMMARY
	echo -n -e "ZFS (LUKS encryption):  \t" | tee -a ./zfsEncryption_SpeedTest_results/ALL_RESULTS_SUMMARY
	printf '%s\t' "${testLUKS_read[@]}" | tee -a ./zfsEncryption_SpeedTest_results/ALL_RESULTS_SUMMARY
	
	echo -e "\n\n----------------------------------------------------------------\n----------------------------------------------------------------\n" | tee -a ./zfsEncryption_SpeedTest_results/ALL_RESULTS_SUMMARY
	
	echo -e "READ -- IOPS \n" | tee -a ./zfsEncryption_SpeedTest_results/ALL_RESULTS_SUMMARY
	echo -n -e "Block Size (KB):        \t" | tee -a ./zfsEncryption_SpeedTest_results/ALL_RESULTS_SUMMARY
	printf '%s\t' "${blockSizeStr[@]}" | tee -a ./zfsEncryption_SpeedTest_results/ALL_RESULTS_SUMMARY
	echo "" | tee -a ./zfsEncryption_SpeedTest_results/ALL_RESULTS_SUMMARY
	echo -n -e "TMPFS:                  \t" | tee -a ./zfsEncryption_SpeedTest_results/ALL_RESULTS_SUMMARY
	printf '%s\t' "${testTMPFS_read_IOPS[@]}" | tee -a ./zfsEncryption_SpeedTest_results/ALL_RESULTS_SUMMARY
	echo "" | tee -a ./zfsEncryption_SpeedTest_results/ALL_RESULTS_SUMMARY
	echo -n -e "ZFS (no encryption):    \t" | tee -a ./zfsEncryption_SpeedTest_results/ALL_RESULTS_SUMMARY
	printf '%s\t' "${testBASE_read_IOPS[@]}" | tee -a ./zfsEncryption_SpeedTest_results/ALL_RESULTS_SUMMARY
	echo "" | tee -a ./zfsEncryption_SpeedTest_results/ALL_RESULTS_SUMMARY
	echo -n -e "ZFS (native encryption):\t" | tee -a ./zfsEncryption_SpeedTest_results/ALL_RESULTS_SUMMARY
	printf '%s\t' "${testZFS_read_IOPS[@]}" | tee -a ./zfsEncryption_SpeedTest_results/ALL_RESULTS_SUMMARY
	echo "" | tee -a ./zfsEncryption_SpeedTest_results/ALL_RESULTS_SUMMARY
	echo -n -e "ZFS (LUKS encryption):  \t" | tee -a ./zfsEncryption_SpeedTest_results/ALL_RESULTS_SUMMARY
	printf '%s\t' "${testLUKS_read_IOPS[@]}" | tee -a ./zfsEncryption_SpeedTest_results/ALL_RESULTS_SUMMARY
	
	echo -e "\n\n----------------------------------------------------------------\n----------------------------------------------------------------\n" | tee -a ./zfsEncryption_SpeedTest_results/ALL_RESULTS_SUMMARY
	
	echo -e "WRITE -- DATA TRANSFER SPEEDS \n" | tee -a ./zfsEncryption_SpeedTest_results/ALL_RESULTS_SUMMARY
	echo -n -e "Block Size (KB):        \t" | tee -a ./zfsEncryption_SpeedTest_results/ALL_RESULTS_SUMMARY
	printf '%s     \t' "${blockSizeStr[@]}" | tee -a ./zfsEncryption_SpeedTest_results/ALL_RESULTS_SUMMARY
	echo "" | tee -a ./zfsEncryption_SpeedTest_results/ALL_RESULTS_SUMMARY
	echo -n -e "TMPFS:                  \t" | tee -a ./zfsEncryption_SpeedTest_results/ALL_RESULTS_SUMMARY
	printf '%s\t' "${testTMPFS_write[@]}" | tee -a ./zfsEncryption_SpeedTest_results/ALL_RESULTS_SUMMARY
	echo "" | tee -a ./zfsEncryption_SpeedTest_results/ALL_RESULTS_SUMMARY
	echo -n -e "ZFS (no encryption):    \t" | tee -a ./zfsEncryption_SpeedTest_results/ALL_RESULTS_SUMMARY
	printf '%s\t' "${testBASE_write[@]}" | tee -a ./zfsEncryption_SpeedTest_results/ALL_RESULTS_SUMMARY
	echo "" | tee -a ./zfsEncryption_SpeedTest_results/ALL_RESULTS_SUMMARY
	echo -n -e "ZFS (native encryption):\t" | tee -a ./zfsEncryption_SpeedTest_results/ALL_RESULTS_SUMMARY
	printf '%s\t' "${testZFS_write[@]}" | tee -a ./zfsEncryption_SpeedTest_results/ALL_RESULTS_SUMMARY
	echo "" | tee -a ./zfsEncryption_SpeedTest_results/ALL_RESULTS_SUMMARY
	echo -n -e "ZFS (LUKS encryption):  \t" | tee -a ./zfsEncryption_SpeedTest_results/ALL_RESULTS_SUMMARY
	printf '%s\t' "${testLUKS_write[@]}" | tee -a ./zfsEncryption_SpeedTest_results/ALL_RESULTS_SUMMARY
	
	echo -e "\n\n----------------------------------------------------------------\n----------------------------------------------------------------\n" | tee -a ./zfsEncryption_SpeedTest_results/ALL_RESULTS_SUMMARY
	
	echo -e "WRITE -- IOPS \n" | tee -a ./zfsEncryption_SpeedTest_results/ALL_RESULTS_SUMMARY
	echo -n -e "Block Size (KB):        \t" | tee -a ./zfsEncryption_SpeedTest_results/ALL_RESULTS_SUMMARY
	printf '%s\t' "${blockSizeStr[@]}" | tee -a ./zfsEncryption_SpeedTest_results/ALL_RESULTS_SUMMARY
	echo "" | tee -a ./zfsEncryption_SpeedTest_results/ALL_RESULTS_SUMMARY
	echo -n -e "TMPFS:                  \t" | tee -a ./zfsEncryption_SpeedTest_results/ALL_RESULTS_SUMMARY
	printf '%s\t' "${testTMPFS_write_IOPS[@]}" | tee -a ./zfsEncryption_SpeedTest_results/ALL_RESULTS_SUMMARY
	echo "" | tee -a ./zfsEncryption_SpeedTest_results/ALL_RESULTS_SUMMARY
	echo -n -e "ZFS (no encryption):    \t" | tee -a ./zfsEncryption_SpeedTest_results/ALL_RESULTS_SUMMARY
	printf '%s\t' "${testBASE_write_IOPS[@]}" | tee -a ./zfsEncryption_SpeedTest_results/ALL_RESULTS_SUMMARY
	echo "" | tee -a ./zfsEncryption_SpeedTest_results/ALL_RESULTS_SUMMARY
	echo -n -e "ZFS (native encryption):\t" | tee -a ./zfsEncryption_SpeedTest_results/ALL_RESULTS_SUMMARY
	printf '%s\t' "${testZFS_write_IOPS[@]}" | tee -a ./zfsEncryption_SpeedTest_results/ALL_RESULTS_SUMMARY
	echo "" | tee -a ./zfsEncryption_SpeedTest_results/ALL_RESULTS_SUMMARY
	echo -n -e "ZFS (LUKS encryption):  \t" | tee -a ./zfsEncryption_SpeedTest_results/ALL_RESULTS_SUMMARY
	printf '%s\t' "${testLUKS_write_IOPS[@]}" | tee -a ./zfsEncryption_SpeedTest_results/ALL_RESULTS_SUMMARY
	
	echo "" | tee -a ./zfsEncryption_SpeedTest_results/ALL_RESULTS_SUMMARY

done

# clean up

# umount ZFS datasets
zfs umount poolBASE/ROOT
zfs umount poolZFS/ROOT
zfs umount poolLUKS/ROOT

# destroy ZFS pools
zpool destroy poolBASE
zpool destroy poolZFS
zpool destroy poolLUKS

# close LUKS device
cryptsetup close "${devLUKS_crypt}"

# detach loop devices
losetup -d "${devBASE}"
losetup -d "${devZFS}"
losetup -d "${devLUKS}"

# umount tmpfs ramdisks
umount /mnt/testTMPFS
umount /mnt/testBASE
umount /mnt/testZFS
umount /mnt/testLUKS


timeEnd="$(date +%s)"
timeElapsed="$((( ${timeEnd} - ${timeStart} )))"

echo "This ZFS Encryption Speed Test took ${timeElapsed} Seconds" >&2