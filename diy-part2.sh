#!/bin/bash
# DIY脚本
# https://github.com/P3TERX/Actions-OpenWrt
# 文件名: diy-part2.sh
# 功能说明: OpenWrt DIY脚本第2部分（更新feeds之后）
# 版权: (c) 2019-2024 P3TERX <https://p3terx.com>
# 基于 MIT 开源协议，详见 /LICENSE

# 修改默认IP地址
#sed -i 's/192.168.1.1/192.168.100.1/g' package/base-files/files/bin/config_generate


# 修改默认主题为 argon（路径不存在时跳过，不中断编译）
sed -i 's/luci-theme-bootstrap/luci-theme-argon/g' feeds/luci/collections/luci/Makefile 2>/dev/null || true

# 启用 IPv4 策略路由（直接写入内核 platform config，绕过 make defconfig 的依赖检查）
# CONFIG_KERNEL_IP_ADVANCED_ROUTER 在 OpenWrt Config.in 中无对应 wrapper，必须用此方式
#for cfg in target/linux/msm89xx/config-*; do
#  grep -q 'CONFIG_IP_ADVANCED_ROUTER' "$cfg" || echo 'CONFIG_IP_ADVANCED_ROUTER=y' >> "$cfg"
#  grep -q 'CONFIG_IP_MULTIPLE_TABLES' "$cfg" || echo 'CONFIG_IP_MULTIPLE_TABLES=y' >> "$cfg"
#done


# 临时添加的插件
# git clone https://github.com/lkiuyu/luci-app-cpu-perf package/luci-app-cpu-perf
# git clone https://github.com/lkiuyu/luci-app-cpu-status package/luci-app-cpu-status
# git clone https://github.com/gSpotx2f/luci-app-cpu-status-mini package/luci-app-cpu-status-mini
# git clone https://github.com/lkiuyu/luci-app-temp-status package/luci-app-temp-status
# git clone https://github.com/lkiuyu/DbusSmsForwardCPlus package/DbusSmsForwardCPlus

# ============================================================
# U01 电池机适配（改包：lkiuyu/immortalwrt 的 msm89xx target，profile=wf2）
#
# 1) 电量来源：打开 PM8916 BMS-VM（电压式电量计，drivers/power/supply/pm8916_bms_vm.c）
#    - 上游 pm8916.dtsi 的 pm8916_charger / pm8916_bms 都写死 status="disabled"，
#      且 config-6.18 里两个驱动符号根本没出现 => 现在 /sys/class/power_supply 是空的。
#    - 充电必须一起开：实测 CHG_CTRL=0x90（bit7 CHG_EN 已经是 1）、USBIN_VALID=1、
#      电池在位、温度 OK，但 IBAT_MAX 停在 PMIC 上电默认 0x00 = 90 mA，
#      插 500 mA 口时系统负载全吃掉 ⇒ 净放电（VSYS 13 分钟 3892→3831 mV）。
#      这个内核没有任何代码去抬它（config-6.18 里连 CHARGER_PM8916_LBC 都没出现），
#      而用户态三条写通道全被配置封死（regmap debugfs 的 registers/access 都是 0400、
#      # CONFIG_DEVMEM is not set、spmi 平台设备没有 resource0）⇒ 只能重编内核打开 lbc。
#    - lbc 的 probe 要抢 usb_vbus 这条 SPMI 中断线（0x13），本机现在由
#      pm8916_usbin (usb-detect@1300) 占着，所以开充电必须同时把它 disable，
#      否则后注册的那个 -EBUSY，充电和电量一起没。
#    - ⚠️ 代价（实测到）：现刷 rootfs 的 /etc/hotplug-gcreboot.json 盯的就是
#      usb-detect 那个 extcon0 的 "USB=0"（拔线）事件，条件成立就 /etc/init.d/gc restart；
#      这台 gc.config.mode=gadget、UDC role=gadget、S90gc 自启 ⇒ 这钩子是活的。
#      关掉 usbin 后 extcon0 消失，钩子不再触发。USB 在/不在这件事本身改由
#      pm8916-lbc 的 extcon 报（同一个 EXTCON_USB），但 DEVPATH/NAME 变了，
#      所以刷好后要按 /sys/class/extcon/*/{name,state} 实测把那份 json 改指过去。
#    - BMS-VM 的 probe 会调 power_supply_get_battery_info()，它在节点上找
#      "monitored-battery" -> compatible="simple-battery"，找不到就 -ENODEV 直接退出，
#      所以必须连电池描述节点一起补，否则驱动根本不绑、白开。
#    - 这个驱动只导出 voltage_now / voltage_ocv / status / health，没有 capacity，
#      所以电量是"电压查表"来的，不是库仑计（插着 USB 时 VBAT 顶在充电压，会显示满格）。
#
# 2) DTS：RGB 灯换成 U01 实脚位（72/71/73，和现在刷进去的 boot_u01.img 一致），
#    再补 4 格电量灯 bat:1..bat:4（脚 0/91/1/100 = 原厂 DTB 的 bat1/batl2/batl3/batl4），
#    并把这 4 个脚加进 &gpio_leds_default 的 pins，否则 pinctrl 不切功能。
#
# 3) 用户态文件走仓库顶层 files/ 覆盖层（不走 package/base-files/files）：
#    上游 include/image.mk 里有 `$(call prepare_rootfs,$(mkfs_cur_target_dir),$(TOPDIR)/files)`
#    ⇒ TOPDIR(files) 才是镜像吃的目录。workflow 先用 `cp -r files openwrt/files` 把它建出来（生效），
#    随后 `mv files openwrt/files` 把仓库根那份搬空、在 openwrt/files/files/ 留一坨重复垃圾
#    （本脚本会顺手删掉）。⇒ 想改 /etc 就往仓库 files/ 里放，但**自检要按 openwrt/files 验**。
#
# 4) DTS 是哪一份：target/linux/msm89xx/image/msm8916.mk 里 openstick-wf2 写死
#    DEVICE_DTS := msm8916-xinxun-wf2 + DEVICE_DTS_DIR := ../dts，
#    Device/Default 是 KERNEL = kernel-bin | gzip | append-dtb，boot.img = append-kernel|aboot-img
#    => 追加到 dts/msm8916-xinxun-wf2.dts 末尾的东西就是刷进去的 DTB（dts/Makefile 那份
#    内核 dtb-y 清单没有 wf2，别被它误导，编译由 OpenWrt 的 Device 规则做）。
#
# 依赖已核对：config-6.18 里 MFD_SPMI_PMIC=y、POWER_SUPPLY=y、EXTCON=y、IIO=y；
#             子目标 msm8916 只有 target.mk（没有自己的 config-6.18）=> 改 target 级那份就够。
# ============================================================
U01_MARK="U01 (battery stick) overrides"

# 内核配置片段的名字必须跟着上游走，不能写死：
#   lkiuyu/immortalwrt 上游锁 7fe583d9 => KERNEL_PATCHVER:=6.12，那棵树里【没有】config-6.18；
#   master HEAD 05d3cf2a             => KERNEL_PATCHVER:=6.18，有 config-6.18 + patches-6.18。
#   写死 config-6.18 的后果：用锁定 hash 编时这文件不存在，echo >> 会凭空造一个没人读的片段，
#   自检还照样"通过"，等于白等一个半小时。所以先解析、再要求它已存在，缺就直接停。
KV=$(sed -n 's/^KERNEL_PATCHVER:=[[:space:]]*\([0-9.][0-9.]*\).*/\1/p' target/linux/msm89xx/Makefile | head -1)
CFG=target/linux/msm89xx/config-$KV
DTS=target/linux/msm89xx/dts/msm8916-xinxun-wf2.dts
for f in "$CFG" "$DTS"; do
	[ -f "$f" ] || { echo "!! KERNEL_PATCHVER=$KV，但 $f 不存在（同目录有：$(ls target/linux/msm89xx/config-* 2>/dev/null | tr '\n' ' ')）"; exit 1; }
done
echo "== U01：KERNEL_PATCHVER=$KV，内核片段 = $CFG =="

for sym in CONFIG_BATTERY_PM8916_BMS_VM CONFIG_CHARGER_PM8916_LBC; do
	grep -q "^${sym}=y" $CFG || echo "${sym}=y" >> $CFG
done
# 注意：这两个是内核内建符号，不是 CONFIG_PACKAGE_*，往 OpenWrt 的 .config 里追加没有意义
#（它们没有 config/Config-kernel.in 里的 CONFIG_KERNEL_* 包装），片段文件才是唯一入口。

if ! grep -q "$U01_MARK" $DTS; then
cat >> $DTS <<'DTSEOF'

/* ---- U01 (battery stick) overrides, injected by diy-part2.sh ---- */
/* production pins: 4g_type=72 -> red/power, 4g_1=71 -> green/wan, wifistatus=73 -> blue/wlan */
&led_r { gpios = <&tlmm 72 GPIO_ACTIVE_HIGH>; };
&led_g { gpios = <&tlmm 71 GPIO_ACTIVE_HIGH>; };
&led_b { gpios = <&tlmm 73 GPIO_ACTIVE_HIGH>; };

/* battery bars: bat1=0, batl3=1, batl2=91, batl4=100 (all four idle in the stock build) */
&leds {
	bat1 { label = "bat:1"; gpios = <&tlmm 0 GPIO_ACTIVE_HIGH>;   default-state = "off"; };
	bat2 { label = "bat:2"; gpios = <&tlmm 91 GPIO_ACTIVE_HIGH>;  default-state = "off"; };
	bat3 { label = "bat:3"; gpios = <&tlmm 1 GPIO_ACTIVE_HIGH>;   default-state = "off"; };
	bat4 { label = "bat:4"; gpios = <&tlmm 100 GPIO_ACTIVE_HIGH>; default-state = "off"; };
};

&gpio_leds_default {
	pins = "gpio0", "gpio1", "gpio12", "gpio22", "gpio31", "gpio38",
	       "gpio71", "gpio72", "gpio73", "gpio91", "gpio97", "gpio98", "gpio100", "gpio108";
};

/ {
	u01_bat: battery {
		compatible = "simple-battery";
		technology = "li-ion";
		voltage-min-design-microvolt = <3400000>;
		voltage-max-design-microvolt = <4200000>;
	};
};

&pm8916_bms {
	status = "okay";
	monitored-battery = <&u01_bat>;
};
DTSEOF
fi

# 充电单独一段：老 fork 已经注入过上面那块（LED/电量灯），只缺这个，重跑也得补上
if ! grep -q '&pm8916_charger' $DTS; then
cat >> $DTS <<'CHGEOF'

/* IBAT_MAX sits at the PMIC power-on default (90 mA) until charger code raises it.
 * usb_vbus is one SPMI line: pm8916_usbin holds it today, so the charger must take it. */
&pm8916_charger {
	status = "okay";
	qcom,fast-charge-safe-voltage = <4200000>;
	qcom,fast-charge-safe-current = <700000>;
	monitored-battery = <&u01_bat>;
};

&pm8916_usbin {
	status = "disabled";
};
CHGEOF
fi

# 用户态（u01simd/netled/ledidle/batled/chg_regs + 四个 init.d + /etc/u01sim.conf
# + etc/uci-defaults/99-u01-lamps）不由本脚本 cp 安装，走仓库顶层 files/ 覆盖层。
# 覆盖层确实生效：上游 include/image.mk 里有 $(call prepare_rootfs,$(mkfs_cur_target_dir),$(TOPDIR)/files)。
#
# ⚠️ 但"仓库根那份 files/"在本步执行时已经不存在了 —— workflow 顺序是
#      step " files"                 : cp -r files openwrt/files        （建目录，这份才算数）
#      step "Load custom configuration": [ -e files ] && mv files openwrt/files
#    第二次是往已存在目录里挪 ⇒ 变成 openwrt/files/files/ 的重复垃圾，仓库根 files/ 被搬空。
#    11-16 那次编译就是在这里自检失败退出的（当时十项全去找仓库根 ⇒ 全空 ⇒ exit 1）。
#    所以要验就验 $(TOPDIR)/files（本步 CWD 就是 openwrt 根），它才是镜像真正吃的那一份。
OVL=files
if [ ! -s "$OVL/usr/libexec/batled.py" ]; then
	for c in "$GITHUB_WORKSPACE/files" "$(dirname -- "$0")/files"; do
		[ -s "$c/usr/libexec/batled.py" ] && { OVL="$c"; break; }
	done
fi
[ -s "$OVL/usr/libexec/batled.py" ] || OVL=""
echo "== U01：覆盖层落点 = ${OVL:-没找到（下面会报缺）} =="
# 清掉 mv 造出来的重复副本，否则它以 /files/ 白占镜像约 100KB
if [ -n "$OVL" ] && [ -s "$OVL/files/usr/libexec/batled.py" ]; then
	rm -rf "$OVL/files" && echo "== U01：已清掉 mv 造成的重复副本 $OVL/files/ =="
fi
# 这里刻意不再往 rc.local 塞 batled.sh：四格灯只留 init.d/batled 一个主人，
# 两份同时跑会抢同一组 bat:1..4，谁最后写谁说了算，格数会乱跳。

# 注入自检：哪一项没落上就直接终止，别花一个半小时编一版跟上一版一样的固件
u01_fail=0
grep -q '^CONFIG_BATTERY_PM8916_BMS_VM=y' $CFG                       || { echo "!! BMS-VM 没进 $CFG"; u01_fail=1; }
grep -q '^CONFIG_CHARGER_PM8916_LBC=y' $CFG                           || { echo "!! CHARGER_PM8916_LBC 没进 $CFG"; u01_fail=1; }
grep -q "DEVICE_DTS := msm8916-xinxun-wf2" target/linux/msm89xx/image/msm8916.mk || echo "!! 警告：上游 device 规则没登记 wf2 的 DTS，$DTS 可能不参与编译"
grep -q "$U01_MARK" $DTS                                             || { echo "!! DTS 没打进 wf2"; u01_fail=1; }
grep -q '&pm8916_charger' $DTS                                       || { echo "!! 充电块没进 $DTS"; u01_fail=1; }
grep -q '&pm8916_usbin' $DTS                                         || { echo "!! 没把 pm8916_usbin 关掉，usb_vbus 中断线会撞车(-EBUSY)"; u01_fail=1; }
grep -q 'u01_bat:' $DTS                                              || { echo "!! $DTS 里没有 u01_bat，充电器引用的 battery 节点不存在"; u01_fail=1; }
# 用户件走 files/ 覆盖层，这里验的是"镜像会吃到的那一份"里十件齐全
# （首启由 etc/uci-defaults/99-u01-lamps 补 chmod + enable，git 带过来的权限位不可靠）
for f in usr/libexec/u01simd.py usr/libexec/netled.py usr/libexec/ledidle.py \
         usr/libexec/batled.py usr/libexec/chg_regs.py \
         etc/init.d/u01sim etc/init.d/netled etc/init.d/ledidle \
         etc/init.d/batled etc/uci-defaults/99-u01-lamps; do
	[ -n "$OVL" ] && [ -s "$OVL/$f" ] || { echo "!! 覆盖层缺文件 $f (OVL=${OVL:-无})"; u01_fail=1; }
done
grep -q '^CONFIG_PACKAGE_python3=y' .config 2>/dev/null \
	|| echo "!! 警告：.config 里 python3 没开，用户态服务全都起不来（应改 config/wf2.config）"
if [ "$u01_fail" != 0 ]; then
	echo "== U01 注入自检失败，终止编译 =="
	ls -l "$OVL/etc/" 2>&1 | sed 's/^/   /'
	exit 1
fi
echo "== U01 注入自检通过：BMS-VM + LBC 充电 + bat:1..4 + 覆盖层用户件齐全 =="
