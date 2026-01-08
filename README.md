# PRIMA_deglitch

Instructions to run and compile.

These steps create a mock datafile, "compile" the VHDL, run it, and run a python plotting code to create a plot to evaluate results. The run step takes about ten minutes to perform the simulation on a 2022-era thinkpad.

```
python3 generate_tdm_data.py
ghdl -a --std=08 pulse_mitigation_tdm.vhd
ghdl -a --std=08 tb_mitigation_tdm.vhd
ghdl -e --std=08 tb_mitigation_tdm
ghdl -r --std=08 tb_mitigation_tdm
ipython
```

(inside ipython, type: )

```
%run plot_tdm_results.py
```
