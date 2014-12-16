#!/bin/sh
geometry=$(fbset | grep geometry)
xres=$(echo $geometry | awk '{print $2}')
yres=$(echo $geometry | awk '{print $3}')
vxres=$(echo $geometry | awk '{print $4}')
vyres=$(echo $geometry | awk '{print $5}')
if [ "$xres" = "$vxres" -a "$yres" = "$vyres" ];then
    :
else
    second_mode=$(resolution|sed -n '2p')
    xres=$(echo $second_mode | awk '{print $1}')
    yres=$(echo $second_mode | awk '{print $2}')
    fbset -xres $xres -yres $yres || true
fi
resolution|sed -n '1!G;h;$p'| uniq | sed 's/ /\n/g' > /tmp/resolution || true
