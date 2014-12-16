#!/bin/bash

grep "generic-loongson-3a-machine" /proc/cpuinfo && ln -sf /root/udisk/boot/vmlinuz-3a /vmlinuz || true
grep "generic-loongson-3b-machine" /proc/cpuinfo && ln -sf /root/udisk/boot/vmlinuz-3b /vmlinuz || true
grep "generic-loongson-3b6-machine" /proc/cpuinfo && ln -sf /root/udisk/boot/vmlinuz-3b6 /vmlinuz || true

