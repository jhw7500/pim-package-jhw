#/bin/bash
tag=$(basename "$0")
KEY=CLK
logger -p local0.notice "[$KEY][$tag:$LINENO] chk cpu clock start"
while :
do
    clk0=$(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_cur_freq)
    #logger -p local0.notice "[$KEY][$tag:$LINENO] cpu0 clock : $clk"
    clk1=$(cat /sys/devices/system/cpu/cpu1/cpufreq/cpuinfo_cur_freq)
    #logger -p local0.notice "[$KEY][$tag:$LINENO] cpu1 clock : $clk"
    clk2=$(cat /sys/devices/system/cpu/cpu2/cpufreq/cpuinfo_cur_freq)
    #logger -p local0.notice "[$KEY][$tag:$LINENO] cpu2 clock : $clk"
    clk3=$(cat /sys/devices/system/cpu/cpu3/cpufreq/cpuinfo_cur_freq)
    #logger -p local0.notice "[$KEY][$tag:$LINENO] cpu3 clock : $clk"
    logger -p local0.notice "[$KEY][$tag:$LINENO] cpu0 clk : $clk0, cpu1 clk : $clk1, cpu2 clk : $clk2, cpu3 clk : $clk3"
    #echo "test"
    sleep 30
done
