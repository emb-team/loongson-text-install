#!/usr/bin/lua

package.path = package.path.."?.lua;../?.lua;../lib/?.lua;../../../lib/?.lua;"
package.cpath = package.cpath.."?.so;../?.so;../lib/?.so;../../../lib/?.so;"

require "mt_lib"
-- require "localcfg"

local md5sum_t = {}
local md5sum_pattern = "(%w+)  ([%w%./%-_]+)[ \t\r]*\n"
local localdisk
local localdisks
local localdir = "/mnt"
local rootdir = "/root"
local udisk_dir = rootdir.."/udisk/"
local ldisk_dir = rootdir.."/ldisk/"
local mount_dir
local backup = "/backup/"
local backup_dir = rootdir..backup
local MPNUM = 4
local ret = 0
local root_i = 0
local home_i = 0
local swap_i = 0
local boot_loc
local sfdisk_prefix

function GetCMDOutput( cmd )
	local fp = io.popen( cmd, "r" )
	local content = fp:read("*a")
	fp:close()
	
	if content == "" then content = nil end
	
	return content	
end

function check_md5sum(dir)
	-- calculate actual md5sum value, now files are all in usb disk
	for k, v in pairs( md5sum_t ) do
		local file = dir..k
		local content = GetCMDOutput( "md5sum "..file )
		if content then
			local value, f = content:match(md5sum_pattern)
			if value then
				if value ~= v then
					LogWrite("Md5sum check error: "..f)
					return -1
				end
			else
				LogWrite("Nil md5sum value: "..file)
				return -1
			end
		else
			LogWrite("No this file? : "..file)
			return -1
		end		
	end
	
	return 0
end

function GetIPs()
	local fd = io.open("/proc/cmdline", "r")
	local content = fd:read("*a")
	local ip = content:match("IP=(%d+%.%d+%.%d+%.%d+)")
	local sip = content:match("SIP=(%d+%.%d+%.%d+%.%d+)")
	fd:close()
	
	return ip, sip
end

function Recover()
	local par = Cfg.default_partitions
	local sfarg = Cfg.sfdisk_arg
	local faction = Cfg.format_table
	local files = Cfg.files_table
	
	if not sfarg or not faction or not files then
		LogWrite("Error! Nil parameters are passed in Recover.")
		MsgWrite("传递给还原程序的参数错误，可能是配置文件格式不正确。", "Error! Nil parameters are passed in Recover.")
		return -1
	end
	
	if Cfg.reco_U then
		LogWrite("we will recover from U disk")
		MsgWrite("本次还原从U盘还原。", "We will recover from U disk.")
	elseif Cfg.reco_D then
		LogWrite("we will recover from hard disk")
		MsgWrite("本次还原从硬盘还原。", "We will recover from hard disk.")
	elseif Cfg.reco_N then
		LogWrite("we will recover from network")
		MsgWrite("本次还原从网络还原。", "We will recover from network.")
	end
	
	if Cfg.whole_recover then
		LogWrite("we will do whole recover")
		MsgWrite("本次还原为全盘整体还原。", "We will do whole recover.")
	elseif Cfg.system_recover then
		LogWrite("we will do system recover")
		MsgWrite("本次还原为系统数据区还原。", "We will do system recover.")
	elseif Cfg.user_recover then
		LogWrite("we will do user recover")
		MsgWrite("本次还原为用户数据区还原。", "We will do user recover.")
	end
	
	-- if boot from U disk
	if (Cfg.reco_U or Cfg.reco_N) and Cfg.whole_recover then
		-- only recover from U disk and whole recover need to do partitions 
		Cfg.new_partition = true	
	end
	
	if Cfg.new_partition then
		-- do partition and format action
		LogWrite("\n================ MAKE PARTITIONS =================")
		MsgWrite("开始分区…", "Make new partitions...")
		local cmd = sfdisk_prefix..sfarg
		LogWrite(cmd)
		ret = do_cmd{cmd}
		if not ret then
			LogWrite("error, hard disk can not be divided")
			MsgWrite("出错，磁盘无法分区！", "Error! Hard disk can not be divided.")
			return -1
		end
		MsgWrite("分区完成。", "Make new partitions done.")
		LogWrite("=============== MAKE PARTITIONS DONE===============")
	end


	LogWrite("\n=============== COPY ===============")
	--if recover from u or net, first format the backup partition
	if Cfg.reco_U or Cfg.reco_N then
		MsgWrite("格式化备份分区…", "Format backup partition...")
		local cmd = "mkfs.ext3 "..localdisk..par["Backup"]
		LogWrite(cmd)
		ret = do_cmd{cmd}
		if not ret then
			LogWrite("format backup partition error")
			MsgWrite("格式化备份分区失败！", "Error! Format backup partition failed.")
			return -1
		end
	end

	-- mount backup directory
	lfs.mkdir(backup_dir)
	if par['Backup'] then
		-- ATTENTION: 
		-- if recover from local disk, if /dev/hda2 has been mounted before,
		-- /dev/hda2 will now have been mounted for twice, to /root/ldisk and /mnt/backup
		local cmd = "mount "..localdisk..par['Backup'].." "..backup_dir
		LogWrite(cmd)
		ret = do_cmd{cmd}
		if not ret then 
			LogWrite("mount backup partition failed")
			MsgWrite("加载备份分区失败！", "Error! Mount backup partition failed.")
			return -1
		end
	end

	--switch to disk log
	LogWrite("now switch to disk log...")
	tmplogfd:close()
	do_cmd { "cp /root/recovery/log.txt "..backup_dir.."log.txt" }
	logfd = io.open(backup_dir.."log.txt", "a")
	if logfd then
		LogWrite("create disk log success")
	else
		LogWrite("create disk log error")
	end

	-- if recover from U disk, do copying files here
	if Cfg.reco_U then
		--system files
		MsgWrite("拷贝系统文件到磁盘…", "Copy system files...")
		for i, v in pairs(files) do
			if v[5] and not lfs.attributes(backup_dir..v[2]) then
				if Cfg.verbose then
					local cmd = "cp -f "..udisk_dir..v[2].." "..backup_dir
					LogWrite(cmd)
					ret = os.execute(cmd)
				else
					lfs.chdir( udisk_dir )
					local cmd = "bar -c 'cat > "..backup_dir.."${bar_file}' "..v[2]
					LogWrite(cmd)
					ret = os.execute(cmd)
					lfs.chdir( "-" )
				end
				if not ret then
					LogWrite("copy system files error")
					MsgWrite("拷贝系统文件时出错！", "Copy system files error!")
					return -1
				end
			end
		end

		--osfab files
		local fab_tbl = Cfg.OSFAB_NAME
		if type(Cfg.OSFAB_NAME) == "string" then
			fab_tbl = {Cfg.OSFAB_NAME}
		end

		for i = 1, #fab_tbl do
			local osfab = fab_tbl[i]
			if osfab and osfab ~= "" and lfs.attributes(udisk_dir..osfab) then
				MsgWrite("拷贝组件映像文件"..osfab.."到磁盘…", "Copy osfab file "..osfab.."...")
				lfs.chdir( udisk_dir )
				local cmd = "bar -c 'cat > "..backup_dir.."${bar_file}' "..osfab
				LogWrite(cmd)
				ret = os.execute(cmd)
				if not ret then
					LogWrite("copy osfab file failed")
					MsgWrite("拷贝组件映像文件失败！", "Copy osfab file failed.")
					return -1
				end
			elseif osfab and osfab ~= "" and not lfs.attributes(udisk_dir..osfab) then
				LogWrite("no osfab file "..osfab..", failed")
				MsgWrite("组件映像文件"..osfab.."不存在, 拷贝失败！", "No osfab file "..osfab..", failed!")
				return -1
			end
		end

		-- copy 'post-recovery' directory from udisk_dir to backup_dir
		do_cmd { "[ -d "..udisk_dir.."post-recovery ] && cp -a "..udisk_dir.."post-recovery "..backup_dir }

		-- copy vmlinux, config.txt, boot.cfg and other files to disk
		do_cmd { "cp /vmlinuz "..backup_dir }
		do_cmd { "cp boot/initrd.cpio.lzma "..backup_dir }
		do_cmd { "cp config.txt "..backup_dir }
		do_cmd { "cp boot.cfg "..backup_dir }
		do_cmd { "cp /root/os_config.txt "..backup_dir }
		if Cfg.check1 then 
			do_cmd { "cp md5sum.txt "..backup_dir }
		end
		do_cmd { "sync" }
		lfs.chdir( "-" )
	end
	
	if Cfg.reco_U then
		lfs.chdir("/")
		-- Umount the usb disk.
		ret = do_cmd { "umount "..udisk_dir }
		if not ret then
			LogWrite("mount USB disk failed")
		else
			LogWrite("**You can take off the USB disk**")
			MsgWrite("**现在可以拨出U盘了**", "**You can take off the USB disk**")
		end
	end

	-- stuff about recover from network
	if Cfg.reco_N then
		-- search ethernet device, and open it
		local content = GetCMDOutput( "ifconfig -a" )
		local ethdev = content:match("eth[%w_]+")
		if not ethdev then
			LogWrite("can't find ethernet device")
			return -1		
		end
		ret = do_cmd { "ifconfig "..ethdev.." up " }
		if not ret then
			LogWrite("can't open ethernet device")
			return -1
		end
		-- get and set local IP
		local ip, sip = GetIPs()
		if not ip then ip = "192.168.1.101" end
		if not sip then sip = "192.168.1.100" end
		
		do_cmd { "ifconfig "..ethdev.." "..ip }
		
		ret = lfs.chdir(backup_dir)
		if not ret then 
			LogWrite("change directory to backup_dir failed")
			MsgWrite("切换到备份目录失败！", "change directory to backup_dir failed.")
			return -1 
		end
		
		local server_dir = "/recovery/latest/"
		-- down system files
		for i, v in pairs(files) do
			if v[5] and not lfs.attributes(v[2]) then
				local basefile = v[2]
				local urlstr = "ftp://"..sip..server_dir..basefile;

				MsgWrite("下载文件："..basefile, "Down file: "..basefile)
				ret = do_cmd { "axel_daogang -n 1 "..urlstr }
				if not ret then
					LogWrite("down file "..basefile.." failed")
					MsgWrite("下载文件："..basefile.."失败。", "Down file "..basefile.." failed.")
					return -1
				end
			end
		end

		-- down component files
		local fab_tbl = Cfg.OSFAB_NAME
		if type(Cfg.OSFAB_NAME) == "string" then
			fab_tbl = {Cfg.OSFAB_NAME}
		end
		for i = 1, #fab_tbl do
			local osfab = fab_tbl[i]
			if osfab and osfab ~= "" and not Cfg.user_recover then
				urlstr = "ftp://"..sip..server_dir..osfab;
				LogWrite("down file: "..urlstr)
				MsgWrite("下载文件："..osfab, "Down file: "..osfab)
				ret = do_cmd { "axel_daogang -n 1 "..urlstr }
				if not ret then
					LogWrite("down file "..urlstr.." failed")
					MsgWrite("下载文件："..osfab.."失败。", "Down file: "..osfab.." failed.")
					return -1
				end
			end
		end

		local other_files = {
			"vmlinuz",
			"config.txt",
			"boot.cfg",
		}
		-- down other files
		for i, v in pairs(other_files) do
			local urlstr = "ftp://"..sip..server_dir..v;

			MsgWrite("下载文件："..v, "Down file: "..v)
			ret = do_cmd { "axel_daogang -n 1 "..urlstr }
			if not ret then
				LogWrite("down file "..v.." failed")
				MsgWrite("下载文件："..v.."失败。", "Down file: "..v.." failed.")								
				return -1
			end
		end

		-- restore original system os_config.txt 
		do_cmd { "cp /root/os_config.txt "..backup_dir }
	end

	-- change directory
	ret = lfs.chdir(backup_dir)
	if not ret then
		LogWrite("change directory to backup_dir failed")
		MsgWrite("切换到备份目录失败！", "Change directory to backup_dir failed!")
		return -1
	end

	-- remove the autostart.txt file, to prevent autostart next time
	do_cmd { "rm autostart.txt" }

	-- calculate actual md5sum value, now files are all in local disk
	if Cfg.check2 then
		if #md5sum_t > 0 then
			LogWrite("--> Now check the md5sum of files on local disk... ")
			MsgWrite("检查本地磁盘上的文件…", "--> Now check the md5sum of files on local disk... ")
			ret = check_md5sum('./')
			if ret ~= 0 then 
				LogWrite("Error when check md5sum of files. \n")
				MsgWrite("文件md5sum值校验出错。", "Error when check md5sum of files!")
				return -1
			else
				LogWrite("OK.\n")
				MsgWrite("文件检查完成。", "Check files done.")
			end
		end
	end
	LogWrite("=============== COPY DONE ===============\n")


	LogWrite("\n=============== FORMAT ===============")
	-- whether do really format depends on the second element in each table of faction
	MsgWrite("开始格式化…", "Do format...")
	for i, v in pairs(faction) do
		if v[2] then
			LogWrite('--> '..v[1].." ... ")
			if Cfg.verbose then
				ret = do_cmd { v[1] }
			else
				ret = do_cmd { v[1]..HO }
			end
			if not ret then
				LogWrite("error, some error occured when format")
				MsgWrite("格式化时出错！", "Error! Some error occured when format.")
				return -1
			end
			LogWrite("OK\n")
		end
	end
	MsgWrite("格式化完成。", "Format done.")
	LogWrite("=============== FORMAT DONE ===============")


	LogWrite("\n=============== MOUNT ===============")
	MsgWrite("加载文件系统…", "Mount file system...")
	-- root partition
	LogWrite("mount root fs")
	ret = do_cmd { "mount "..localdisk..root_i.." "..localdir }
	if not ret then
		LogWrite("mount root partition failed")
		MsgWrite("加载根文件系统失败！", "Mount root partition failed!")
		return -1
	end


	LogWrite("=============== MOUNT DONE ===============\n")


	LogWrite("\n=================== EXTRACT ==================")
	MsgWrite("解压文件…", "Extract files...")
	--extract root partition
	for i, v in pairs(files) do
		if v[3] == localdir.."/" and v[5] then
			local cmd
			if Cfg.verbose then
				cmd = "tar xvf "..v[2].." -m -C "..localdir..v[4]
			else
				cmd = "bar "..v[2].." | tar xzf - -m -C "..localdir..v[4]
			end
			LogWrite(cmd)
			ret = do_cmd{cmd}
			if not ret then
				LogWrite("extract root partition files error")
				MsgWrite("解压根分区文件出错！", "Extract root partition files error!")
				return -1 
			end
		end
	end

	--extract other partitions
	for i, v in pairs(files) do
		if v[3] ~= localdir.."/" and v[5] then
			if not lfs.attributes(v[3]) then
				lfs.mkdir(v[3])
			end
			local cmd = "mount "..localdisk..v[1].." "..v[3]
			LogWrite(cmd)
			ret = do_cmd{cmd}
			if not ret then
				LogWrite("mount "..localdisk..v[1].." error")
				MsgWrite("挂载设备"..localdisk..v[1].."失败！", "Mount "..localdisk..v[1].." error!")
				return -1
			end

			--extract
			if Cfg.verbose then
				cmd = "tar xvf "..v[2].." -m -C "..localdir.." "..v[4].." || tar xvf "..v[2].." -m -C "..localdir.." ./"..v[4]
			else
				cmd = "bar "..v[2].." | tar xzf - -m -C "..localdir.." "..v[4].." || bar "..v[2].." | tar xzf - -m -C "..localdir.." ./"..v[4]
			end
			LogWrite(cmd)
			ret = do_cmd{cmd}
			if not ret then 
				LogWrite("extract error")
				MsgWrite("解压出错！", "Extract error!")
				return -1 
			end
		end
	end	

	do_cmd { "sync" }

	-- mount proc fs
	LogWrite("mount proc fs")
	do_cmd { "mount none -t proc "..localdir.."/proc" }
	-- mount proc fs
	do_cmd { "mount -o bind /dev "..localdir.."/dev" }
	-- mount proc fs
	do_cmd { "mount -o bind /sys "..localdir.."/sys" }

	-- mount tmpfs
	LogWrite("mount tmpfs")
	do_cmd {"mount none -t tmpfs "..localdir.."/tmp"}

	MsgWrite("文件解压完成。", "Extract files done.")
	LogWrite("=============== EXTRACT DONE ===============\n")


	-- generate fstab
	LogWrite("next we generate fstab file")
	local fd = io.open(localdir.."/etc/fstab", "w")
	if not fd then
		LogWrite("error, can't open etc/fstab")
		return -1
	end
	fd:write("#<file system>\t<mount point>\t<type>\t<options>\t<dump>\t<pass>\n")

	for i, v in ipairs(par) do
		-- for normal partitions
		if v[MPNUM] then
			fd:write("/dev/sda"..i..'\t')
			fd:write(v[MPNUM]..'\t')
			fd:write(v[2]..'\t')
			fd:write("defaults\t")
			fd:write("0\t0\n")
		end
		-- for swap partition 
		if v[2] == "swap" then
			fd:write("/dev/sda"..i..'\t')
			fd:write("none\t")
			fd:write("swap\t")
			fd:write("sw\t")
			fd:write("0\t0\n")
		end
	end
	-- add tmpfs
	fd:write("shm\t")
	fd:write("/tmp\t")
	fd:write("tmpfs\t")
	fd:write("defaults\t")
	fd:write("0\t0\n")
	fd:close()

	-- generate boot.cfg on /boot and copy vmlinuz
	--[[
	local bc = Cfg.default_bootcfg
	if bc then
		LogWrite("next we generate boot.cfg file")
		local bootn = par['Boot'] or 1
		local bootdir = "/bootcfg/"
		lfs.mkdir(bootdir)
		ret = do_cmd { "mount "..localdisk..bootn.." "..bootdir }
		if not ret then 
			LogWrite("mount boot partition failed")
			return -1	
		end
		local fd = io.open(bootdir.."boot.cfg", "w")
		fd:write("default "..(bc.default_boot or 0)..'\n')
		fd:write("showmenu "..(bc.show_menu or 1)..'\n\n')
		--recover title
		local rec_title = 0
		local pmon_num1 = bc.pmonver:match("LM(%d+)%-%d%.%d%.%d")
		if pmon_num1 then
			local pmon_num2 = string.byte(bc.pmonver:match("LM%d+%-(%d)%.%d%.%d"))-48
			local pmon_num3 = string.byte(bc.pmonver:match("LM%d+%-%d%.(%d)%.%d"))-48
			local pmon_num4 = string.byte(bc.pmonver:match("LM%d+%-%d%.%d%.(%d)"))-48
			LogWrite("PMON_VER=LM"..pmon_num1.."-"..pmon_num2..pmon_num3..pmon_num4)
			if pmon_num1 == "6004" and
				((pmon_num2 > 1)
				or (pmon_num2 == 1 and pmon_num3 > 3)
				or (pmon_num2 == 1 and pmon_num3 == 3 and pmon_num4 >= 5)) then
				rec_title = 1
			end
			if pmon_num1 == "8089" and
				((pmon_num2 > 1)
				or (pmon_num2 == 1 and pmon_num3 > 4)
				or (pmon_num2 == 1 and pmon_num3 == 4 and pmon_num4 >= 6)) then
				rec_title = 1
			end
			if pmon_num1 == "9002" and
				((pmon_num2 > 1)
				or (pmon_num2 == 1 and pmon_num3 > 4)
				or (pmon_num2 == 1 and pmon_num3 == 4 and pmon_num4 >= 0)) then
				rec_title = 1
			end
			if pmon_num1 == "9003" or pmon_num1 == "9013" or pmon_num1 == "9020" then
				rec_title = 1
			end
		end
		if rec_title == 1 then
			fd:write("title Lemote Recovery Tool\n")
			local chr = string.char(string.byte('a') + Cfg.default_partitions.Backup - 1)
			fd:write("\tkernel /dev/fs/ext2@"..boot_loc..chr.."/vmlinuz\n")
			fd:write("\targs console=tty machtype="..(bc.machtype or "yeeloong").." "..(bc.res or "").." resume="..localdisk..swap_i.." recover=localdisk\n")
			fd:write("\trecovery 0\n\n")
		end
		--boot title
		fd:write("title "..bc.title.." "..bc.ver..'\n')
		local ch = string.char(string.byte('a') + root_i - 1)
		fd:write("\tkernel /dev/fs/ext2@"..boot_loc..ch.."/boot/vmlinuz26\n")
		fd:write("\targs console=tty no_auto_cmd quiet root="..localdisk..(root_i or 1).." machtype="..(bc.machtype or "yeeloong").." "..(bc.res or "").." resume="..localdisk..swap_i)

		fd:close()
	end
	]]

	-- we will get system version
	local version = ""
	local fd = io.open("/proc/cmdline", "r")
	if fd then
		content = fd:read("*a")
		if content then
			version = content:match("version=([%w-]+)")
		end
		fd:close()
	else
		LogWrite("Missing /proc/cmdline file in system?")
		MsgWrite("缺少版本类型配置: /proc/cmdline?", "Missing /proc/cmdline file in system?")
		return -1
	end

	LogWrite("next we generate boot.cfg file")
	local bootex = Cfg.BOOT_EX or ""
	local bootn = par['Boot'] or 1
	local bootdir = "/bootcfg/"
	local bc = Cfg.default_bootcfg
	lfs.mkdir(bootdir)
	ret = do_cmd { "mount "..localdisk..bootn.." "..bootdir }
	if not ret then 
		LogWrite("mount boot partition failed")
		return -1	
	end
	local fd = io.open(bootdir.."boot.cfg", "w")
	bootex = string.gsub(bootex, "#{MACHTYPE}#", bc.machtype)
	fd:write(string.gsub(bootex, "#{VERSION}#", version))
	fd:close()

	-- grub.cfg
	local bootgb = Cfg.BOOT_GB or ""
	if 0 < string.len(bootgb) then
		LogWrite("next we generate grub.cfg file")
		lfs.mkdir(bootdir.."/boot/")
		fd = io.open(bootdir.."/boot/grub.cfg", "w")
		bootgb = string.gsub(bootgb, "#{MACHTYPE}#", bc.machtype)
		fd:write(string.gsub(bootgb, "#{VERSION}#", version))
		fd:close()
	end

	-- do_cmd { "cp /mnt/boot/vmlinuz26 "..bootdir }
	do_cmd { "sync" }	
	LogWrite("\n======================= Main Body End ========================\n")
	
	-- clean, dangerous!
	if Cfg.clean then
		do_cmd { "rm -rf "..backup_dir.."/*" }
	end
			
	return 0
end

function PrintHead()

	do_cmd { "clear" }
	LogWrite("")
	LogWrite("=====================================================================")
	LogWrite("||                                                                 ||")
	LogWrite("||                         START RECOVERY                          ||")
	LogWrite("||                                                                 ||")
	LogWrite("=====================================================================")
	LogWrite("")
	mt.sleep(2)
end

function PrintBigPass()
	local big_pass = [[
			=========================================================
 			|                                                       |
			|        ########      ###      ######    ######        |
			|        ##     ##    ## ##    ##    ##  ##    ##       |
			|        ##     ##   ##   ##   ##        ##             |
			|        ########   ##     ##   ######    ######        |
			|        ##         #########        ##        ##       |
			|        ##         ##     ##  ##    ##  ##    ##       |
			|        ##         ##     ##   ######    ######        |
			|                                                       |
			=========================================================
	]]
	LogWrite(big_pass)
	mt.sleep(3)
end


function PrintBigFailure()
	local big_failure = [[
			=========================================================
			|                                                       |
			|  ########    ###    #### ##       ######## ########   |
			|  ##         ## ##    ##  ##       ##       ##     ##  |
			|  ##        ##   ##   ##  ##       ##       ##     ##  |
			|  ######   ##     ##  ##  ##       ######   ##     ##  |
			|  ##       #########  ##  ##       ##       ##     ##  |
			|  ##       ##     ##  ##  ##       ##       ##     ##  |
			|  ##       ##     ## #### ######## ######## ########   |
			|                                                       |
			========================================================= 
	]]
	
	LogWrite(big_failure)

end

function collect_info()

	if Cfg.reco_N then	
		-- search ethernet device, and open it
		local content = GetCMDOutput( "ifconfig -a" )
		local ethdev = content:match("eth[%w_]+")
		if not ethdev then
			LogWrite("can't find ethernet device")
			return -1		
		end
		ret = do_cmd { "ifconfig "..ethdev.." up " }
		if not ret then
			LogWrite("can't open ethernet device")
			return -1
		end

		-- get and set local IP
		local ip, sip = GetIPs()
		if not ip then ip = "192.168.1.101" end
		if not sip then sip = "192.168.1.100" end
		
		do_cmd { "ifconfig "..ethdev.." "..ip }
		-- remove the old config.txt in /root/recovery/
		do_cmd { "rm ./config.txt" }
				
		local server_dir = "/recovery/latest/"
		-- down system files
		local file = "config.txt"
		local urlstr = "ftp://"..sip..server_dir..file;

		MsgWrite("下载配置文件…", "Down files...")
		ret = do_cmd { "axel_daogang -n 1 "..urlstr }
		if not ret then
			LogWrite("down file "..file.." failed")
			MsgWrite("下载配置文件："..file.."失败。", "Down file "..file.." failed!")
			return -1
		end
		LogWrite("down file "..file.." success")
		MsgWrite("配置文件下载成功。", "Down file "..file.." success.")		
		
		-- import new config.txt file
		dofile("./config.txt")
	end

	--if the config.txt is old version, correct it
	CheckCfgVer()

	-- start parse parameters
	local par = Cfg.default_partitions
	local args = ""
	
	local r_format_types = {}
	for _, v in ipairs(Cfg.format_types) do
		r_format_types[v] = true		
	end
	
	-- arguments check
	for i = 1, #par do
		local size = par[i][1]
		local format_type = par[i][2]
		local format = par[i][3]
		
		-- column one
		if type(size) ~= 'number' 
			and size ~= 'NULL' 
			and size ~= 'rest' 
		then
			LogWrite("Error! One of the size in column Size is not number, NULL, or rest.")
			MsgWrite("Size参数不正确！", "Error! One of the size in column Size is not number, NULL, or rest.")
			return -1
		end
		
		-- column two
		if not r_format_types[format_type] then
			LogWrite("Error! One of the type of format in column Type is not right. \nOnly ext2, ext3, ext4, swap, extend is permitted.")
			MsgWrite("Format type参数不正确！", "Error! One of the type of format in column Type is not right.")
			return -1
		end 
		
		-- column three
		if format ~= 'Y' and format ~= 'N' and format ~= 'NULL' then
			LogWrite("Error! One of the value in column Format is not right. \nOnly Y, N, NULL are permitted.")
			MsgWrite("是否格式化标志不正确！", "Error! One of the value in column Format is not right.")
			return -1
		end
		
		-- the rest columns must all be string
		-- so don't need to check them  
	
	end
	-----------------------------------------------------------------------
	-- The following codes don't need to judge the LogWrite
	-----------------------------------------------------------------------
	-- 
	for i = 1, #par do
		local size = par[i][1]
		local format_type = par[i][2]
		local format = par[i][3]
	
		-- form sfdisk_arg
		if type(size) == 'number' then
			if format_type == "swap" then
				args = args..','..tostring(size)..",S\n"
			else	
				args = args..','..tostring(size)..",L\n"
			end
		elseif size == 'NULL' then
			args = args..",,E\n"
		elseif size == 'rest' then
			args = args..",,\n"
		end
	end
	args = args.."EOF\n"			

	-- till now, sfdisk_arg has been formed
	Cfg.sfdisk_arg = args
	
	for i, v in ipairs(par) do
		if v[MPNUM] == '/' then	root_i = i end
		if v[MPNUM] == '/home' then home_i = i end
		if v[2] == 'swap' then swap_i = i end
	end
	-- we must consider the partition of /home is the same to /
	if home_i == 0 then home_i = root_i end
	
	-- next, we are going to form format_table: have two columns, only record real parititions 
	for i = 1, #par do
		local size = par[i][1]
		local format_type = par[i][2]
		local format = par[i][3]
	
		-- form format_table
		if format_type == 'extend' then
			-- nothing to do
		elseif format_type == 'swap' then
			Cfg.format_table[i] = {}
			Cfg.format_table[i][1] = "mkswap "..localdisk..i
			Cfg.format_table[i][2] = true
		elseif format_type == 'fat' then
			Cfg.format_table[i] = {}
			Cfg.format_table[i][1] = "mkfs.vfat "..localdisk..i		
			if format == 'Y' then
				Cfg.format_table[i][2] = true
			else
				Cfg.format_table[i][2] = false
			end
		elseif format_type == 'ext4' then
		 	Cfg.format_table[i] = {}
			Cfg.format_table[i][1] = "mkfs.ext4 "..localdisk..i
			if format == 'Y' then
				Cfg.format_table[i][2] = true
			else
				Cfg.format_table[i][2] = false
			end
		elseif format_type == 'ext3' then
		 	Cfg.format_table[i] = {}
			Cfg.format_table[i][1] = "mkfs.ext3 "..localdisk..i
			if format == 'Y' then
				Cfg.format_table[i][2] = true
			else
				Cfg.format_table[i][2] = false
			end
		elseif format_type == 'ext2' then
			Cfg.format_table[i] = {}
			Cfg.format_table[i][1] = "mkfs.ext2 "..localdisk..i
			if format == 'Y' then
				Cfg.format_table[i][2] = true
			else
				Cfg.format_table[i][2] = false
			end
		end

		-- boot and backup partitions only support ext3
		if i == par.Boot or i == par.Backup then
			Cfg.format_table[i][1] = "mkfs.ext3 "..localdisk..i
		end	
		-- if we boot from local disk, we won't format the boot partition
		if Cfg.reco_D and i == par.Boot then
			Cfg.format_table[i][2] = false
		end
		-- set for reco_D, reco_N and reco_U ignore this step
		if i == par.Backup then
			Cfg.format_table[i][2] = false
		end
		-- if we use system recovery mode, we won't format home partition
		if Cfg.system_recover and i == home_i then
			Cfg.format_table[i][2] = false
		end
		-- we should't format any partition except home when in user recover mode
		if Cfg.user_recover and i ~= home_i and Cfg.format_table[i] then
			Cfg.format_table[i][2] = false
		end
	end

	-- next we will form files_table: have three columns, 
	-- we should use some method to determine what package will be extracted
	local file_count = 0
	for i = 1, #par do
		local v = par[i]
		local n = #v
		-- collect files
		if n > MPNUM then
			for j = MPNUM+1, n do
				file_count = file_count + 1
				Cfg.files_table[file_count] = {}
				Cfg.files_table[file_count][1] = i
				Cfg.files_table[file_count][2] = v[j]
				Cfg.files_table[file_count][3] = localdir..v[MPNUM]

				if v[MPNUM] == "/" then
					Cfg.files_table[file_count][4] = ""
				else
					Cfg.files_table[file_count][4] = v[MPNUM]:match("/(.+)")
				end

				Cfg.files_table[file_count][5] = true
				if Cfg.system_recover and v[MPNUM] == "/home" then
					Cfg.files_table[file_count][5] = false
				elseif Cfg.user_recover and v[MPNUM] ~= "/home" then
					Cfg.files_table[file_count][5] = false
				end

				if not Cfg.reco_N and not lfs.attributes(mount_dir..v[j]) then
					LogWrite(v[j].." does not exist.")
					MsgWrite("缺少文件"..v[j].."，请确保该文件存在或者尝试从其他途径还原。", v[j].."does not exist, please ensure this file is available, or try to recover form other way.")
					return -1
				end
			end
		end
	end

	-- acoording to the mount point and file name to determin what should be extracted
	for i, v in ipairs(Cfg.files_table) do
		for j, w in ipairs(Cfg.files_table) do
			if v[2] == w[2] and v[3] ~= w[3] and v[3] == localdir.."/" then
				v[4] = v[4].." --exclude="..w[4].."/* --exclude=./"..w[4].."/*"
			end
		end
	end

	-- next we will choose machine type boot cfg
	local fd = io.open("/proc/cpuinfo", "r")
	if fd then
		content = fd:read("*a")
		if content then
			Cfg.default_bootcfg = {}
			Cfg.default_bootcfg.machtype = content:match("system type%s+:%s+([%w-]+)")
		end
		fd:close()
	else
		LogWrite("Missing /proc/cpuinfo file in system?")
		MsgWrite("缺少机器类型配置: /proc/cpuinfo?", "Missing /proc/cpuinfo file in system?")
		return -1
	end

	return 0
end

function InstallComponents()
	local machine = ""
	local fd = io.open("/proc/cpuinfo", "r")
	if fd then
		content = fd:read("*a")
		if content then
			machine = content:match("system type%s+:%s+([%w-]+)")
			if machine == nil or machine == "undefined" then
				LogWrite("Missing machtype in /proc/cpuinfo?")
				MsgWrite("缺少机器类型配置: /proc/cpuinfo?", "Missing machtype in /proc/cpuinfo?")
				return -1
			end
		end
		fd:close()
	else
		LogWrite("Missing /proc/cpuinfo file in system?")
		MsgWrite("缺少机器类型配置: /proc/cpuinfo?", "Missing /proc/cpuinfo file in system?")
		return -1
	end
	local fabdir = "/osfab"
	local rec_mode = "both"
	local resolution = ""

	--machine type for lynloong-9003
	if machine:match("lemote-lynloong-2f-9003") then
		machine = "lynloong-2f-9003"
	end

	if Cfg.system_recover then
		rec_mode = "system"
		os.execute("mount "..localdisk..home_i.." "..localdir.."/home")
	elseif Cfg.user_recover then
		rec_mode = "data"
	end

	if not putENV then
		LogWrite("Have no putENV function. Stop.")
		return -1
	end

	-- next we will get system version
	local version = ""
	local fd = io.open("/proc/cmdline", "r")
	if fd then
		content = fd:read("*a")
		if content then
			version = content:match("version=([%w-]+)")
		end
		fd:close()
	else
		LogWrite("Missing /proc/cmdline file in system?")
		MsgWrite("缺少版本类型配置: /proc/cmdline?", "Missing /proc/cmdline file in system?")
		return -1
	end

	-- set some environment variables
	putENV("MOUNT_POINT="..(localdir or "/mnt"))
	putENV("MACHINE_TYPE="..(machine or "yeeloong"))
	putENV("SYSTEM_VERSION="..(version or ""))
	putENV("RESOLUTION="..(resolution or "1024x768"))
	putENV("RECOVER_MODE="..rec_mode)

	-- now, we define in the case of whole and system recover, it needs to install components
	LogWrite("=============== INSTALL OSFAB ===============")
	LogWrite("make /osfab directory")
	do_cmd { "mkdir -p "..fabdir }

	local fab_tbl = Cfg.OSFAB_NAME
	if type(Cfg.OSFAB_NAME) == "string" then
		fab_tbl = {Cfg.OSFAB_NAME}
	end

	for i = 1, #fab_tbl do
		local osfab = fab_tbl[i]
		if osfab and osfab ~= "" and lfs.attributes(backup_dir..osfab) then
			--mount
			LogWrite("mount osfab file "..osfab)
			ret = do_cmd { "mount "..backup_dir..osfab.." -o loop,ro "..fabdir } 
			if not ret then
				LogWrite("mount osfab file "..osfab.." failed")
				MsgWrite("挂载组件映像文件"..osfab.."失败！", "Mount osfab file "..osfab.." failed.")
				return -1
			end

			--install
			lfs.chdir(fabdir)
			LogWrite("install osfab file "..osfab.."...")
			MsgWrite("正在安装组件"..osfab.."…", "Install osfab file "..osfab.."...")
			if Cfg.whole_recover or Cfg.system_recover then
				ret = do_cmd {"bash select_install.sh 1>>"..backup_dir.."log.txt 2>&1"}
				if not ret then
					ret = do_cmd{"bash run.sh 1>>"..backup_dir.."log.txt 2>&1"}
					if not ret then
						LogWrite("install osfab file "..osfab.." failed")
						MsgWrite("安装组件"..osfab.."时出错！", "Install osfab file "..osfab.." failed!")
						return -1
					end
				end
			elseif lfs.attributes("run.sh") then
				ret = do_cmd{"bash run.sh 1>>"..backup_dir.."log.txt 2>&1"}
				if not ret then
					LogWrite("install osfab file "..osfab.." failed")
					MsgWrite("安装组件"..osfab.."时出错！", "Install osfab file "..osfab.." failed!")
					return -1
				end
			end

			--umount
			lfs.chdir(backup_dir)
			ret = do_cmd{"umount "..fabdir}
			if not ret then
				LogWrite("umount osfab file "..osfab.." failed")
			end
		end
	end

	LogWrite("=============== INSTALL OSFAB DONE ===============\n")
	return 0
end


function backupHomeDirectory()
	-- first time, backup the home data to /backup
	if (Cfg.reco_U or Cfg.reco_N) and Cfg.whole_recover and Cfg.SYSTEM_NAME:match("Cocreate") then
		LogWrite("Begin to generate home_backup.tar.gz.")
		-- backup /mnt/home	
		lfs.chdir(localdir)
		ret = do_cmd { "tar cf "..backup_dir..home_backup.." home" }
		if not ret then
			LogWrite("Warning! Backup home user data failed.")
		end
		lfs.chdir('-')
	end
end


function LogWrite(str)
	if logfd then
		logfd:write(str.."\n")
		logfd:flush()
	elseif tmplogfd then
		tmplogfd:write(str.."\n")
		tmplogfd:flush()
	end
end

function MsgWrite(str_c, str_e)
	if Cfg.LANGUAGE == "eng" then
		printMsg(str_e)
	else
		printMsg(str_c)
	end
end

function CheckCfgVer()
	if not Cfg.CONFIG_VERSION or Cfg.CONFIG_VERSION == "" then
		LogWrite("old config.txt version")
		local par = Cfg.default_partitions
		local root_file

		for i, v in ipairs(par) do
			if v[MPNUM] == '/' then
				root_file = v[MPNUM + 1]
			end
		end

		for i = 1, #par do
			local v = par[i]
			local n = #v
			if n == MPNUM and v[MPNUM] and v[MPNUM] ~= "/" then
				v[MPNUM + 1] = root_file
				LogWrite("item "..v[MPNUM].." is filled with file: "..root_file)
			end
		end
	end

	return 0
end


--===================================================================
-- START
--===================================================================
-- mt.sleep(10)


tmplogfd = io.open("/root/recovery/log.txt", "w")

--do_cmd { "date -s 20121221" }
do_cmd { "setterm -blank 0" }

PrintHead()

local ver_fd = io.open("/root/recovery/version.txt", "r")
local ver_content = ver_fd:read("*a")
if ver_content then
	LogWrite("recovery tool version: "..ver_content)
end


local fdisk_output = GetCMDOutput( "fdisk -l ")
local is_hda = fdisk_output:match("/dev/hda")
if is_hda then
	localdisk = "/dev/hda"
	sfdisk_prefix = "sfdisk -uM /dev/hda 1>/dev/null 2>&1 <<EOF\n"
	boot_loc = "wd0"
else
	localdisks = io.popen("for disk in `ls -l /sys/block | grep pci | grep -v usb | grep -v loop | grep -v ram | awk '{print $9}'`; do size=`cat /sys/block/${disk}/size`; removable=`cat /sys/block/${disk}/removable`;  if [ \"0\" != \"${size}\" -a \"0\" = \"${removable}\" ]; then echo ${disk}; break; fi done")
	localdisk = "/dev/"..localdisks:read()
	sfdisk_prefix = "sfdisk -uM "..localdisk.." 1>/dev/null 2>&1 <<EOF\n"
	boot_loc = "sata0"
end

-- find the size of local disk
fdisk_output = GetCMDOutput( "fdisk -l "..localdisk)
local real_disksize, unit = fdisk_output:match(": ([%d%.]+) ([GM])B,")
real_disksize = tonumber(real_disksize)

-- convert megabytes to gigabytes
if unit == 'M' then
	real_disksize = real_disksize / 1024
end

-- script self containing
if not printMsg then
	printMsg = LogWrite
end

-- here, need to judge where the vmlinuz boot from
-- we use mounted information to distinguish
if Cfg.reco_N then
	Cfg.reco_U = false
	Cfg.reco_D = false
	
	if Cfg.user_recover then
		Cfg.whole_recover = true
		Cfg.system_recover = false
		Cfg.user_recover = false
	end
else
	if Cfg.reco_U then
		mount_dir = udisk_dir
	elseif Cfg.reco_D then
		mount_dir = ldisk_dir
	end
end

-- ensure Cfg have values
if Cfg.reco_U or Cfg.reco_D then
	if not Cfg.default_partitions then
		LogWrite("Can't load global configuration, please check this file: config.txt.")
		MsgWrite("无法找到全局配置变量！请检查config.txt文件。", "Can't load global configuration, please check this file: config.txt.")
		return -1
	end
end

-- if external disksize is smaller than internal disksize, go ahead normally
if Cfg.disksize <= real_disksize then
	-- after this function, the config table has been transformed as the internal expresstion
	-- Cfg.default_partitions
	-- Cfg.sfdisk_arg
	-- Cfg.format_table
	-- Cfg.files_table
	if collect_info() == -1 then
		return -1
	end
else
	LogWrite("The disk size of machine is too small.")
	MsgWrite("配置文件中指定的磁盘大小过大（大于实际磁盘容量）！请修改此参数。", "The disk size of machine is too small.")
	return -1
end

-- backup the os_config.txt from the backup partition to /root
if (Cfg.reco_U or Cfg.reco_N) and (Cfg.whole_recover or Cfg.system_recover) then
	local num = Cfg.default_partitions.Backup
	do_cmd { "mount "..localdisk..num.." /mnt/" }
	do_cmd { "cp /mnt/os_config.txt /root/" }
	do_cmd { "umount /mnt" }
end	

-- WRONG: Recover backup partition from disk will not do partition action
-- if we don't umount backup partition, it will fail in later mount action.
-- if Cfg.reco_D then
local content = GetCMDOutput( "mount" )
if content:match("/root/ldisk") then
	ret = do_cmd { "umount "..ldisk_dir }
	if not ret then
		LogWrite("Umount backup partition failed.")
		MsgWrite("卸载备份分区失败。", "Umount backup partition failed.")
		return -1
	end
end
-- end	


-- before recovery, we want a memory test
if Cfg.premem then
	LogWrite("\n--> Pre Memory Test")
	ret = do_cmd { "memtester_little 960 1" }
	if not ret then
		LogWrite("memory test is failed")
		return -1
	end
end

-- check files' md5sum on U disk
if Cfg.check1 and Cfg.reco_U then
	-- read md5sum.txt
	local fd = io.open(udisk_dir.."md5sum.txt", 'r')
	if not fd then 
		LogWrite("can't find file: md5sum.txt, we will not execute md5sum check")
		MsgWrite("找不到md5sum.txt文件，跳过md5码校验。", "Can't find file: md5sum.txt. We will not execute md5sum check.") 
		Cfg.check1 = false
		Cfg.check2 = false
	end
	
	if Cfg.check1 then
		local md5_file = fd:read("*a")
		fd:close()
		-- retrieve md5sum value of every bin file, files in md5sum can be more than actual file number
		local l = 1
		local value, filename
		while l do
			_, l, value, filename = md5_file:find(md5sum_pattern, l)
			if l then 
				md5sum_t[filename] = value
			end
		end

		-- calculate actual md5sum value, now files are all in usb disk
		LogWrite("now check the md5sum of files on usb disk")
		MsgWrite("检查U盘上的文件的完整性", "--> Now check the md5sum of files on usb disk... ")
		ret = check_md5sum(udisk_dir)
		if ret ~= 0 then 
			LogWrite("error when check md5sum of files \n")
			MsgWrite("文件md5sum值校验出错。", "Error when check md5sum of files. \n")
			return -1
		else
			LogWrite("OK\n")	
			MsgWrite("文件检查完成。", "Check files done.")
		end
	end
end

-- Main Work
local ret = Recover()
if ret ~= 0 then
	LogWrite("error when recover")
	return -1
end

ret = InstallComponents()
if ret ~= 0 then
	LogWrite("error when install components")
	return -1
end

--cp vmlinuz to boot_partion
ret = do_cmd {"cd /"}
ret = do_cmd {"mkdir /boot_for_kernel"}
ret = do_cmd {"mount "..localdisk.."1 /boot_for_kernel"}
ret = do_cmd {"sleep 1"}
ret = do_cmd { "cp -af /mnt/boot/* /boot_for_kernel"}
do_cmd {"sync"}


--backupHomeDirectory()

--hook
LogWrite("last step: setup a hook of finish recovery")
MsgWrite("创建还原结束钩子程序…", "Setup a hook of finish recovery...")
ret = lfs.chdir(backup_dir.."post-recovery")
if not ret then
	LogWrite("can not open "..backup_dir.."post-recovery, skip")
	MsgWrite("无法进入post-recovery目录，跳过该步骤", "Can not open "..backup_dir.."post-recovery, skip.")
else
	LogWrite("execute run.sh...")
	MsgWrite("执行run.sh脚本…", "Execute run.sh...")
	ret = do_cmd{"bash run.sh 1>>"..backup_dir.."log.txt 2>&1"}
	if not ret then
		LogWrite("error when execute run.sh, skip")
		MsgWrite("执行run.sh脚本时错误，跳过该步骤。", "Error when execute run.sh, skip.")
	end
end
--end of hook

LogWrite("\n============================ END ===========================\n")

PrintBigPass()

logfd:close()

return 0
-- do_cmd { "reboot" }
--==================================================================
-- END
--==================================================================
