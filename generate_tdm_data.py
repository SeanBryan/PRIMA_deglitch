import numpy as np
import sys

# Parameters
n_detectors = 2000
n_samples = 3000
# REVISED: Reduced scale factor to prevent int16 overflow (Previous fix)
scale_factor = 512.0 

# Output files
f_data = open("input_tdm.txt", "w")
f_cfg = open("config_tdm.txt", "w")

print(f"Generating physics-based data for {n_detectors} detectors with DC Steps...")

# Storage for config to write later
config_storage = {}

for d in range(n_detectors):
    # 1. Random DC baseline (unique per detector)
    dc_i = np.random.randint(-1000, 1000)
    dc_q = np.random.randint(-1000, 1000)
    
    # 2. Random Glitch Direction (Phase angle)
    glitch_angle = np.random.uniform(0, 2*np.pi)
    
    # 3. Define the DC Step-Change (Flux Jump)
    # Occurs at a random time between sample 200 and 800
    jump_time = np.random.randint(200, 800)
    
    # Jump size roughly +/- 100 (randomized slightly)
    # We ensure it's significant enough to likely cause a trigger event
    jump_i = int(np.random.choice([-1, 1]) * np.random.normal(200, 20))
    jump_q = int(np.random.choice([-1, 1]) * np.random.normal(200, 20))

    # Generate Time Series
    # Create empty arrays
    raw_i = np.zeros(n_samples)
    raw_q = np.zeros(n_samples)
    
    # Add random pulses
    n_pulses = int(np.round(n_samples/300))
    pulse_locs = np.sort(np.random.randint(50, n_samples-50, n_pulses))
    
    for t in range(n_samples):
        # Base signal starts at DC
        val_i = float(dc_i)
        val_q = float(dc_q)
        
        # --- INJECT DC STEP CHANGE ---
        if t >= jump_time:
            val_i += jump_i
            val_q += jump_q
        # -----------------------------

        # Add Noise (Gaussian)
        noise_i = np.random.normal(0, 5.0)
        noise_q = np.random.normal(0, 5.0)
        
        val_i += noise_i
        val_q += noise_q
        
        # Add Pulses (Simple exponential decay)
        for loc in pulse_locs:
            if t >= loc and t < loc + 50:
                # Pulse amplitude
                amp = 300.0 * np.exp(-(t - loc)/10.0)
                # Project pulse onto I/Q based on angle
                val_i += amp * np.cos(glitch_angle)
                val_q += amp * np.sin(glitch_angle)
        
        # Clip to int16 range
        val_i = np.clip(val_i, -32767, 32767)
        val_q = np.clip(val_q, -32767, 32767)
        
        raw_i[t] = val_i
        raw_q[t] = val_q

    # Write Data to File (Interleaved for TDM: Det0, Det1, Det2... then next sample)
    # Note: This script generates all samples for Det0, then Det1. 
    # To write strictly interleaved as the FPGA expects (Sample0_D0, Sample0_D1...), 
    # we would need to store all data in RAM first. 
    # For simplicity, we will assume the testbench reads this linearly 
    # and we will write it line-by-line per detector here.
    # *Correction*: The previous VHDL testbench reads 2000 lines per sample.
    # To keep this script simple and memory efficient, we will just write 
    # the detectors sequentially to a list, then transpose write.
    
    # Actually, let's just save the config now and deal with data writing structure.
    
    # --- CALIBRATION LOGIC (Computed on PRE-JUMP DC levels) ---
    cfg_mean_i = dc_i
    cfg_mean_q = dc_q
    
    cfg_a_i = int(-scale_factor * np.cos(glitch_angle))
    cfg_a_q = int(-scale_factor * np.sin(glitch_angle))
    
    effective_amp = np.sqrt(cfg_a_i**2 + cfg_a_q**2) 
    sigma_metric = effective_amp * 5.0
    
    cfg_hi_th = int(-5.0 * sigma_metric)
    cfg_lo_th = int(-0.5 * sigma_metric)
    
    config_storage[d] = [cfg_mean_i, cfg_mean_q, cfg_a_i, cfg_a_q, cfg_hi_th, cfg_lo_th]
    
    # Store data for interleaving
    if d == 0:
        all_data_i = np.zeros((n_detectors, n_samples), dtype=int)
        all_data_q = np.zeros((n_detectors, n_samples), dtype=int)
        
    all_data_i[d, :] = raw_i
    all_data_q[d, :] = raw_q

# Write Config File
for d in range(n_detectors):
    c = config_storage[d]
    line = f"{c[0]} {c[1]} {c[2]} {c[3]} {c[4]} {c[5]}\n"
    f_cfg.write(line)
f_cfg.close()

# Write Data File (Interleaved Time First)
# Time 0: Det 0, Det 1 ... Det N
# Time 1: Det 0, Det 1 ... Det N
print("Writing interleaved data...")
for t in range(n_samples):
    for d in range(n_detectors):
        line = f"{all_data_i[d,t]} {all_data_q[d,t]}\n"
        f_data.write(line)

f_data.close()
print("Done.")