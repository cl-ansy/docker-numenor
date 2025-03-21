sudo mount -t nfs $IP:/data/shared /nfs/readynas/shared
echo "$IP:/data/shared /nfs/readynas/shared nfs defaults 0 0" | sudo tee -a /etc/fstab
