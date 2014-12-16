#!/usr/bin/lua

local rootdir = "/root"
local udisk_dir = rootdir.."/udisk/"
local ldisk_dir = rootdir.."/ldisk/"
local ndisk_dir = rootdir.."/ndisk/"

function FindAndMountUDisk()
    os.execute("sleep 2")
    local part
    local usb_dev_file
    local fd = io.popen("cat /proc/cmdline")
    local machtype
    local usb_dev = nil
    if fd then
        local content = fd:read("*line")
        if content == nil then
            return -1
        else
            machtype = content:match("machtype=([%w_%-%.]+)")
        end
        local cdrom = io.open("/dev/sr0", "r")
        if cdrom ~= nil then
            usb_dev = "sr0"
            io.close(cdrom)
        else
            usb_dev_file = io.popen("for usb in `ls -l /sys/block | grep usb | awk '{print $9}'`; do size=`cat /sys/block/${usb}/size`;  if [ \"0\" != \"${size}\" ]; then echo ${usb}; fi done")
            usb_dev=usb_dev_file:read("*line")
        end
    end

    if usb_dev == nil then
        return -1
    end

    part = "/dev/"..usb_dev
    local ret = nil 
    if usb_dev == "sr0" then
        ret = os.execute( "mount -o ro "..part.." "..udisk_dir )
        if ret ~= 0 then
            return -1
        end
    else
        ret = os.execute( "mount -o ro "..part.." "..udisk_dir )
        if ret ~= 0 then
            part = part.."1"			
            ret = os.execute( "mount -o ro "..part.." "..udisk_dir )
            if ret ~= 0 then
                return -1 
            end
        end
    end     
    return 0
end

--
-- find U disk, mount it, and copy essential files into inner disk
--
os.execute("mkdir  -p "..udisk_dir)
os.execute("mkdir  -p "..ldisk_dir)
os.execute("mkdir  -p "..ndisk_dir)

-- mount the second partition to local_dir
ret = os.execute("mount /dev/sda2 "..ldisk_dir)
if ret == 0 then
    print("Mount local disk success.")
    ret = FindAndMountUDisk()
    if ret ~= 0 then
        print("Mount USB disk error.")
    else
        print("Mount USB disk success.")
    end
else
    print("Mount local disk error.")
    ret = FindAndMountUDisk()
    if ret ~= 0 then
        print("Mount USB disk error.")
        print("Quit.")
        return -1
    else
        print("Mount USB disk success.")
    end
end

return 0
