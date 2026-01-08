library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity pulse_mitigation_tdm is
    generic(
        NUM_DETECTORS : integer := 2000
    );
    port(
        clk         : in  std_logic;
        rst         : in  std_logic;
        
        -- CONFIGURATION PORT
        conf_we     : in  std_logic;
        conf_addr   : in  integer range 0 to NUM_DETECTORS-1;
        conf_meanI  : in  signed(15 downto 0);
        conf_meanQ  : in  signed(15 downto 0);
        conf_aI     : in  signed(15 downto 0);
        conf_aQ     : in  signed(15 downto 0);
        conf_hi_th  : in  signed(15 downto 0);
        conf_lo_th  : in  signed(15 downto 0);

        -- DATA STREAM PORT
        frame_start : in  std_logic; 
        I_in        : in  signed(15 downto 0);
        Q_in        : in  signed(15 downto 0);
        
        -- OUTPUTS
        valid_out   : out std_logic;
        I_out       : out signed(15 downto 0);
        Q_out       : out signed(15 downto 0);
        trigger_out : out std_logic
    );
end pulse_mitigation_tdm;

architecture rtl of pulse_mitigation_tdm is
    
    -- ========================================================================
    -- CONSTANTS & TYPES
    -- ========================================================================
    constant Nbuffer  : integer := 16;
    constant Ntriglim : integer := 128; 
    
    -- Buffer for Signal Data (16-bit)
    type buffer_array is array(0 to Nbuffer-1) of signed(15 downto 0);
    
    -- NEW: Buffer for Phase Data (37-bit) to support baseline averaging
    type phase_buffer_array is array(0 to Nbuffer-1) of signed(36 downto 0);
    
    type det_context_t is record
        -- Config
        meanI, meanQ : signed(15 downto 0);
        aI, aQ       : signed(15 downto 0);
        hi_th, lo_th : signed(15 downto 0);
        
        -- Signal State
        I_buf, Q_buf : buffer_array;
        last_I, last_Q : signed(15 downto 0);
        
        -- Phase State
        phase_buf      : phase_buffer_array; -- History of phase values
        last_phase_base: signed(36 downto 0);-- Frozen baseline during trigger
        
        -- Logic State
        triggered    : boolean;
        untrigger_cnt: unsigned(15 downto 0);
        triggered_cnt: unsigned(15 downto 0);
    end record;

    constant RESET_CONTEXT : det_context_t := (
        meanI=>(others=>'0'), meanQ=>(others=>'0'),
        aI=>(others=>'0'), aQ=>(others=>'0'),
        hi_th=>(others=>'0'), lo_th=>(others=>'0'),
        I_buf=>(others=>(others=>'0')), Q_buf=>(others=>(others=>'0')),
        last_I=>(others=>'0'), last_Q=>(others=>'0'),
        phase_buf=>(others=>(others=>'0')),
        last_phase_base=>(others=>'0'),
        triggered=>false, 
        untrigger_cnt=>(others=>'1'),
        triggered_cnt=>(others=>'0')
    );

    -- ========================================================================
    -- BRAM DECLARATION
    -- ========================================================================
    type ram_t is array (0 to NUM_DETECTORS-1) of det_context_t;
    signal RAM : ram_t := (others => RESET_CONTEXT);
    attribute ram_style : string;
    attribute ram_style of RAM : signal is "block"; 

    -- ========================================================================
    -- PIPELINE SIGNALS
    -- ========================================================================
    signal s0_det_idx, s1_det_idx : integer range 0 to NUM_DETECTORS-1 := 0;
    signal s0_active, s1_active   : std_logic := '0';
    signal s1_I_in, s1_Q_in       : signed(15 downto 0) := (others=>'0');

    attribute use_dsp : string;
    attribute use_dsp of rtl : architecture is "yes";

begin

    process(clk)
        variable v_ctx : det_context_t; 
        
        -- Math vars
        variable diffI, diffQ : signed(16 downto 0);
        variable mult_I, mult_Q : signed(35 downto 0);
        variable phase_inst : signed(36 downto 0); 
        
        -- Averaging vars
        variable avg_I_sum, avg_Q_sum : signed(17 downto 0);
        variable avg_I, avg_Q : signed(15 downto 0);
        
        variable avg_phase_sum : signed(38 downto 0); -- Sum of 4x 37-bit numbers
        variable phase_avg_calc : signed(36 downto 0);
        variable phase_rel : signed(36 downto 0);
        
        variable trig_start, trig_end : boolean;
        variable force_untrigger : boolean; 
    begin
        if rising_edge(clk) then

            -- ================================================================
            -- CONFIG WRITE
            -- ================================================================
            if conf_we = '1' then
                RAM(conf_addr).meanI <= conf_meanI;
                RAM(conf_addr).meanQ <= conf_meanQ;
                RAM(conf_addr).aI    <= conf_aI;
                RAM(conf_addr).aQ    <= conf_aQ;
                RAM(conf_addr).hi_th <= conf_hi_th;
                RAM(conf_addr).lo_th <= conf_lo_th;
                
                -- Full Reset
                RAM(conf_addr).triggered <= false;
                RAM(conf_addr).untrigger_cnt <= (others => '1');
                RAM(conf_addr).triggered_cnt <= (others => '0');
                RAM(conf_addr).last_phase_base <= (others => '0');
            end if;

            -- ================================================================
            -- STAGE 0 & 1 (Address Generation & Delay)
            -- ================================================================
            if rst = '1' then
                s0_active <= '0'; s0_det_idx <= 0;
            else
                if frame_start = '1' then
                    s0_det_idx <= 0; s0_active <= '1';
                elsif s0_active = '1' then
                    if s0_det_idx = NUM_DETECTORS - 1 then
                        s0_active <= '0'; s0_det_idx <= 0;
                    else
                        s0_det_idx <= s0_det_idx + 1;
                    end if;
                end if;
            end if;
            s1_active  <= s0_active;
            s1_det_idx <= s0_det_idx;
            s1_I_in    <= I_in; 
            s1_Q_in    <= Q_in;

            -- ================================================================
            -- STAGE 2: Processing
            -- ================================================================
            if s1_active = '1' then
                v_ctx := RAM(s1_det_idx); 

                -- 1. INSTANTANEOUS PHASE CALCULATION
                diffI := resize(s1_I_in, 17) - resize(v_ctx.meanI, 17);
                diffQ := resize(s1_Q_in, 17) - resize(v_ctx.meanQ, 17);
                mult_I := resize(v_ctx.aI, 18) * resize(diffI, 18);
                mult_Q := resize(v_ctx.aQ, 18) * resize(diffQ, 18);
                phase_inst := resize(mult_I, 37) + resize(mult_Q, 37);

                -- 2. BUFFER UPDATES (SHIFT)
                v_ctx.I_buf(1 to Nbuffer-1) := v_ctx.I_buf(0 to Nbuffer-2);
                v_ctx.Q_buf(1 to Nbuffer-1) := v_ctx.Q_buf(0 to Nbuffer-2);
                v_ctx.phase_buf(1 to Nbuffer-1) := v_ctx.phase_buf(0 to Nbuffer-2);
                
                v_ctx.I_buf(0) := s1_I_in;
                v_ctx.Q_buf(0) := s1_Q_in;
                v_ctx.phase_buf(0) := phase_inst;

                -- 3. CALCULATE AVERAGES (I, Q, and PHASE)
                -- Using delayed window (indices 12-15) to look "before" the event
                avg_I_sum := resize(v_ctx.I_buf(12), 18) + resize(v_ctx.I_buf(13), 18) + 
                             resize(v_ctx.I_buf(14), 18) + resize(v_ctx.I_buf(15), 18);
                avg_Q_sum := resize(v_ctx.Q_buf(12), 18) + resize(v_ctx.Q_buf(13), 18) + 
                             resize(v_ctx.Q_buf(14), 18) + resize(v_ctx.Q_buf(15), 18);
                
                avg_phase_sum := resize(v_ctx.phase_buf(12), 39) + resize(v_ctx.phase_buf(13), 39) + 
                                 resize(v_ctx.phase_buf(14), 39) + resize(v_ctx.phase_buf(15), 39);
                
                avg_I := resize(avg_I_sum / 4, 16);
                avg_Q := resize(avg_Q_sum / 4, 16);
                phase_avg_calc := resize(avg_phase_sum / 4, 37);

                -- 4. THRESHOLD CHECK LOGIC
                -- If not triggered, we use the live average.
                -- If triggered, we use the FROZEN baseline (v_ctx.last_phase_base).
                if not v_ctx.triggered then
                    phase_rel := phase_inst - phase_avg_calc;
                else
                    phase_rel := phase_inst - v_ctx.last_phase_base;
                end if;

                trig_start := (phase_rel < resize(v_ctx.hi_th, 37));
                trig_end   := (phase_rel > resize(v_ctx.lo_th, 37));

                -- 5. STATE MACHINE
                if not v_ctx.triggered then
                    -- NORMAL MODE
                    v_ctx.triggered_cnt := (others => '0'); 
                    
                    -- Update the LATCHED baselines (track the live signal)
                    v_ctx.last_I := avg_I;
                    v_ctx.last_Q := avg_Q;
                    v_ctx.last_phase_base := phase_avg_calc; -- Track phase baseline

                    if v_ctx.untrigger_cnt < (Nbuffer * 3) then
                        -- Recovery Hold-off
                        I_out <= v_ctx.last_I;
                        Q_out <= v_ctx.last_Q;
                        v_ctx.untrigger_cnt := v_ctx.untrigger_cnt + 1;
                        trigger_out <= '0';
                    else
                        -- Pass Through
                        I_out <= v_ctx.I_buf(Nbuffer-1);
                        Q_out <= v_ctx.Q_buf(Nbuffer-1);
                        
                        if trig_start then
                            v_ctx.triggered := true;
                            trigger_out <= '1';
                        else
                            trigger_out <= '0';
                        end if;
                    end if;
                else
                    -- TRIGGERED MODE
                    -- Outputs are frozen to the last known good values (latched above)
                    I_out <= v_ctx.last_I;
                    Q_out <= v_ctx.last_Q;
                    trigger_out <= '1';
                    
                    v_ctx.triggered_cnt := v_ctx.triggered_cnt + 1;
                    
                    force_untrigger := (v_ctx.triggered_cnt >= Ntriglim);
                    
                    if trig_end or force_untrigger then
                        -- EXIT TRIGGER
                        v_ctx.triggered := false;
                        v_ctx.untrigger_cnt := (others => '0');
                        v_ctx.triggered_cnt := (others => '0');
                        
                        -- WATCHDOG NOTE:
                        -- If we forced untrigger, we simply exit.
                        -- In the NEXT clock cycle, 'triggered' will be false.
                        -- The logic will enter 'NORMAL MODE' above.
                        -- It will calculate 'phase_avg_calc' from the buffer.
                        -- Since the buffer has been filling for 128 cycles, 
                        -- 'phase_avg_calc' will EQUAL the new DC level.
                        -- 'v_ctx.last_phase_base' will update to this new level.
                        -- Adaptation is automatic.
                    end if;
                end if;
                
                valid_out <= '1';

                if conf_we = '0' then
                    RAM(s1_det_idx) <= v_ctx;
                end if;
            else
                valid_out <= '0';
                trigger_out <= '0';
            end if;
        end if;
    end process;
end rtl;