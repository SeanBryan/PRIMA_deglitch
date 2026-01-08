library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use std.env.all;

entity tb_mitigation_tdm is
end tb_mitigation_tdm;

architecture behavior of tb_mitigation_tdm is

    constant NUM_DETECTORS : integer := 2000;
    constant clk_period : time := 50 ns; 

    -- COMPONENT DECLARATION
    -- Updated to match the entity constraints exactly
    component pulse_mitigation_tdm
        generic( NUM_DETECTORS : integer );
        port(
            clk, rst    : in std_logic;
            conf_we     : in std_logic;
            conf_addr   : in integer range 0 to NUM_DETECTORS-1; -- FIX: Added Range
            conf_meanI, conf_meanQ : in signed(15 downto 0);
            conf_aI, conf_aQ       : in signed(15 downto 0);
            conf_hi_th, conf_lo_th : in signed(15 downto 0);
            frame_start : in std_logic;
            I_in, Q_in  : in signed(15 downto 0);
            valid_out   : out std_logic;
            I_out, Q_out: out signed(15 downto 0);
            trigger_out : out std_logic
        );
    end component;

    -- Signals
    signal clk, rst : std_logic := '0';
    signal frame_start : std_logic := '0';
    
    -- Config Signals
    signal conf_we : std_logic := '0';
    -- FIX: Added Range to signal as well
    signal conf_addr : integer range 0 to NUM_DETECTORS-1 := 0; 
    signal c_mI, c_mQ, c_aI, c_aQ, c_hi, c_lo : signed(15 downto 0) := (others=>'0');
    
    -- Data Signals
    signal I_in, Q_in : signed(15 downto 0) := (others => '0');
    signal valid_out, trig_out : std_logic;
    signal I_out, Q_out : signed(15 downto 0);
    
    signal sim_finished : boolean := false;

begin

    uut: pulse_mitigation_tdm
        generic map( NUM_DETECTORS => NUM_DETECTORS )
        port map(
            clk => clk, rst => rst,
            conf_we => conf_we, conf_addr => conf_addr,
            conf_meanI => c_mI, conf_meanQ => c_mQ,
            conf_aI => c_aI, conf_aQ => c_aQ,
            conf_hi_th => c_hi, conf_lo_th => c_lo,
            frame_start => frame_start,
            I_in => I_in, Q_in => Q_in,
            valid_out => valid_out, I_out => I_out, Q_out => Q_out,
            trigger_out => trig_out
        );

    -- Clock
    process begin
        while not sim_finished loop
            clk <= '0'; wait for clk_period/2;
            clk <= '1'; wait for clk_period/2;
        end loop;
        wait;
    end process;

    -- Main Stimulus
    process
        file infile : text open read_mode is "input_tdm.txt";
        file cfgfile : text open read_mode is "config_tdm.txt";
        variable inline, cfgline : line;
        variable v_I, v_Q : integer;
        variable v_c1, v_c2, v_c3, v_c4, v_c5, v_c6 : integer;
    begin
        rst <= '1';
        wait for 200 ns;
        rst <= '0';
        wait for 200 ns;
        
        -- ==========================================
        -- PHASE 1: LOAD CONFIGURATION
        -- ==========================================
        report "Loading Configuration into FPGA BRAM..." severity note;
        conf_we <= '1';
        
        for i in 0 to NUM_DETECTORS-1 loop
            if not endfile(cfgfile) then
                readline(cfgfile, cfgline);
                read(cfgline, v_c1); read(cfgline, v_c2); -- Means
                read(cfgline, v_c3); read(cfgline, v_c4); -- As
                read(cfgline, v_c5); read(cfgline, v_c6); -- Thresholds
                
                conf_addr <= i;
                c_mI <= to_signed(v_c1, 16); c_mQ <= to_signed(v_c2, 16);
                c_aI <= to_signed(v_c3, 16); c_aQ <= to_signed(v_c4, 16);
                c_hi <= to_signed(v_c5, 16); c_lo <= to_signed(v_c6, 16);
                
                wait for clk_period;
            end if;
        end loop;
        
        conf_we <= '0';
        wait for 10 * clk_period; -- Wait for "Done"
        
        -- ==========================================
        -- PHASE 2: RUN DATA PROCESSING
        -- ==========================================
        report "Starting Data Stream..." severity note;
        
        while not endfile(infile) loop
            frame_start <= '1';
            wait for clk_period;
            frame_start <= '0';
            
            for d in 0 to NUM_DETECTORS-1 loop
                if not endfile(infile) then
                    readline(infile, inline);
                    read(inline, v_I); read(inline, v_Q);
                    I_in <= to_signed(v_I, 16);
                    Q_in <= to_signed(v_Q, 16);
                    wait for clk_period;
                else
                    exit;
                end if;
            end loop;
            
            I_in <= (others=>'0'); Q_in <= (others=>'0');
            wait for 5 * clk_period;
        end loop;
        
        wait for 100 * clk_period;
        sim_finished <= true;
        stop;
        wait;
    end process;

-- Monitor Process
    process
        file outfile : text open write_mode is "output_tdm.txt";
        variable outline : line;
        variable v_out_I, v_out_Q : integer;
        variable v_trig_int : integer; -- Variable to hold integer version of trigger
    begin
        wait until rst = '0';
        while not sim_finished loop
            wait until rising_edge(clk);
            if valid_out = '1' then
                v_out_I := to_integer(I_out);
                v_out_Q := to_integer(Q_out);
                
                -- Convert std_logic to Integer (0 or 1) to avoid quotes in output file
                if trig_out = '1' then 
                    v_trig_int := 1; 
                else 
                    v_trig_int := 0; 
                end if;

                write(outline, v_out_I);    write(outline, string'(" "));
                write(outline, v_out_Q);    write(outline, string'(" "));
                write(outline, v_trig_int); -- Writes 1 or 0 (clean, no quotes)
                writeline(outfile, outline);
            end if;
        end loop;
        wait;
    end process;

end behavior;