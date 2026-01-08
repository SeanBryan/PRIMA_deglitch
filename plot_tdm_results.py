import numpy as np
import matplotlib.pyplot as plt

def load_and_reshape(filename, num_detectors, num_cols):
    print(f"Loading {filename}...")
    try:
        raw_data = np.loadtxt(filename)
    except OSError:
        print(f"Error: Could not find {filename}. Run the simulation first.")
        exit()

    # Calculate number of time samples based on file length
    total_lines = raw_data.shape[0]
    num_samples = total_lines // num_detectors
    
    # Reshape: The file is organized as [Time 0 (All Dets), Time 1 (All Dets)...]
    # Shape becomes (Time, Detectors, Columns)
    reshaped_data = raw_data.reshape(num_samples, num_detectors, num_cols)
    
    # Transpose to (Detectors, Time, Columns)
    return reshaped_data.transpose(1, 0, 2)

# =========================================================
# CONFIGURATION
# =========================================================
NUM_DETECTORS = 2000
NUM_PLOTS = 3

# =========================================================
# LOAD DATA
# =========================================================
# Input: I, Q (2 columns)
input_data = load_and_reshape("input_tdm.txt", NUM_DETECTORS, 2)

# Output: I, Q, Trigger (3 columns)
output_data = load_and_reshape("output_tdm.txt", NUM_DETECTORS, 3)

# Pick 3 random detectors
random_indices = np.random.choice(NUM_DETECTORS, NUM_PLOTS, replace=False)
random_indices = np.sort(random_indices) # Sort just for nicer labeling

# =========================================================
# PLOTTING
# =========================================================
fig, axes = plt.subplots(NUM_PLOTS, 1, figsize=(10, 12), sharex=True)
if NUM_PLOTS == 1: axes = [axes] # Handle edge case if user changes NUM_PLOTS to 1

print(f"Plotting Detectors: {random_indices}")

for i, det_idx in enumerate(random_indices):
    ax = axes[i]
    
    # Extract Data for this detector
    # (Plotting I-channel only for clarity, as Q behaves identically)
    in_I  = input_data[det_idx, :, 0]
    out_I = output_data[det_idx, :, 0]
    trig  = output_data[det_idx, :, 2]
    time  = np.arange(len(in_I))
    
    # 1. Plot Raw Input
    ax.plot(time, in_I, label='Input (Raw)', color='lightgray', alpha=0.8)
    
    # 2. Plot Processed Output
    ax.plot(time, out_I, label='Output (Cleaned)', color='tab:blue', linewidth=1.5)
    
    # 3. Highlight Triggered Regions
    # Fill red where trigger is high
    ax.fill_between(time, np.min(in_I), np.max(in_I), where=(trig==1), 
                    color='red', alpha=0.15, label='Trigger Active')

    # 4. Detect and Annotate Watchdog Events
    # Find start and end indices of trigger events
    trig_diff = np.diff(np.concatenate(([0], trig, [0])))
    starts = np.where(trig_diff == 1)[0]
    ends = np.where(trig_diff == -1)[0]

    for s, e in zip(starts, ends):
        duration = e - s
        # If duration matches our Ntriglim (256), flag it
        if duration >= 256:
            mid_x = e
            val_y = out_I[e]
            ax.annotate(f'Watchdog Reset\n({duration} samples)', 
                        xy=(mid_x, val_y), 
                        xytext=(mid_x + 50, val_y + (np.max(in_I)*0.2)),
                        arrowprops=dict(facecolor='black', shrink=0.05, width=1, headwidth=5),
                        fontsize=9, color='darkred', weight='bold')

    ax.set_ylabel(f"Det {det_idx} (I-channel)")
    ax.legend(loc='upper right', fontsize='small')
    ax.grid(True, linestyle='--', alpha=0.5)

axes[-1].set_xlabel("Time (Samples)")
plt.suptitle(f"TDM Pulse Mitigation: Watchdog Test (Random Selection)", fontsize=14)
plt.tight_layout(rect=[0, 0.03, 1, 0.97])
plt.show()