-------------------------------------------------------------------------
-- Henry Duwe
-- Department of Electrical and Computer Engineering
-- Iowa State University
-------------------------------------------------------------------------


-- RISCV_Processor.vhd
-------------------------------------------------------------------------
-- DESCRIPTION: THIS IS SHAWN AND JAY'S PIPELINED PROCESSOR! This file will contain hardware five-stage
--pipeline handling 
--  ---./3810_tf.sh test --summary proj/riscv/cpre3810_test_assembly_program/*.s
-- 01/29/2019 by H3::Design created.
-- 04/10/2025 by AP::Coverted to RISC-V.
-- 02/19/2026 by H3::Renamed PC and handled OVFL
-------------------------------------------------------------------------


library IEEE;
use IEEE.std_logic_1164.all;

library work;
use work.RISCV_types.all;

entity RISCV_Processor is
  generic(N : integer := DATA_WIDTH);
  port(iCLK            : in std_logic;
       iRST            : in std_logic;
       iInstLd         : in std_logic;
       iInstAddr       : in std_logic_vector(N-1 downto 0);
       iInstExt        : in std_logic_vector(N-1 downto 0);
       oALUOut         : out std_logic_vector(N-1 downto 0); -- TODO: Hook this up to the output of the ALU. It is important for synthesis that you have this output that can effectively be impacted by all other components so they are not optimized away.
       oHalt           : out std_logic); -- exposes s_Halt (WFI fully retired through WB) to the outside world

end  RISCV_Processor;


architecture structure of RISCV_Processor is

  -- Required data memory signals
  signal s_DMemWr       : std_logic; -- TODO: use this signal as the final active high data memory write enable signal
  signal s_DMemAddr     : std_logic_vector(N-1 downto 0); -- TODO: use this signal as the final data memory address input
  signal s_DMemData     : std_logic_vector(N-1 downto 0); -- TODO: use this signal as the final data memory data input
  signal s_DMemOut      : std_logic_vector(N-1 downto 0); -- TODO: use this signal as the data memory output
 
  -- Required register file signals 
  signal s_RegWr        : std_logic; -- TODO: use this signal as the final active high write enable input to the register file
  signal s_RegWrAddr    : std_logic_vector(4 downto 0); -- TODO: use this signal as the final destination register address input
  signal s_RegWrData    : std_logic_vector(N-1 downto 0); -- TODO: use this signal as the final data memory data input

  -- Required instruction memory signals
  signal s_IMemAddr     : std_logic_vector(N-1 downto 0); -- Do not assign this signal, assign to s_PC instead
  signal s_PC 		: std_logic_vector(N-1 downto 0); -- TODO: use this signal as your intended final instruction memory address input.
  signal s_Inst         : std_logic_vector(N-1 downto 0); -- TODO: use this signal as the instruction signal 

  -- Required halt signal -- for simulation
  signal s_Halt         : std_logic;  -- TODO: this signal indicates to the simulation that intended program execution has completed. (Use WFI with Opcode: 111 0011 func3: 000 and func12: 000100000101 -- func12 is imm field from I-format)

  -- Required overflow signal -- for overflow exception detection
  signal s_Ovfl         : std_logic;  -- this signal indicates an overflow exception would have been initiated

  component mem is
    generic(ADDR_WIDTH : integer;
            DATA_WIDTH : integer;
            INIT_FILE  : string := "");
    port(
          clk          : in std_logic;
          addr         : in std_logic_vector((ADDR_WIDTH-1) downto 0);
          data         : in std_logic_vector((DATA_WIDTH-1) downto 0);
          we           : in std_logic := '1';
          q            : out std_logic_vector((DATA_WIDTH -1) downto 0));
    end component;

  -- TODO: You may add any additional signals or components your implementation 
  --       requires below this comment


 -- ======= ADDED SIGNALS ========= -- 


  signal s_MemToReg	: std_logic_vector(1 downto 0); 
  signal s_PC_plus4	: std_logic_vector(N-1 downto 0); 

  signal s_EX_BranchTaken 	: std_logic; 
--  signal s_funct3	: std_logic_vector(2 downto 0); 
  signal s_ALU_Zero	: std_logic;
  signal s_ALU_SLT	: std_logic_vector(N-1 downto 0); 
  signal s_ALU_SLTU	: std_logic_vector(N-1 downto 0); 

  signal s_rs1_data	: std_logic_vector(N-1 downto 0); 
  signal s_rs2_data	: std_logic_vector(N-1 downto 0); 
  signal s_B_ALU_choice	: std_logic_vector(N-1 downto 0); 

  signal s_ALUOut	: std_logic_vector(N-1 downto 0); 

  signal s_ALUSrc	: std_logic; 
  signal s_Jump		: std_logic; 
  signal s_Branch	: std_logic; 
  signal s_PC_SRC	: std_logic; 
  signal s_ALUOp	: std_logic_vector(2 downto 0); 
  signal s_ALUCtrl	: std_logic_vector(3 downto 0); 
  signal s_RegWrite	: std_logic; 
  signal s_MemWrite	: std_logic; 
  signal s_MemRead	: std_logic; 
  signal s_immediate	: std_logic_vector(N-1 downto 0); 
  signal s_LoadData  	: std_logic_vector(N-1 downto 0);
  signal s_HaltCtrl  	: std_logic;

-- FLUSH SIGNALS -- 
--signal s_WE_gated	: std_logic; 
signal s_flush_IFID	: std_logic; 
signal s_flush_IDEX	: std_logic; 


-- STALL SIGNALS -- 
signal s_stall		: std_logic; 
signal s_stall_n	: std_logic; 
--FETCH SIGNALS--
signal s_jal_target	: std_logic_vector(31 downto 0);
signal s_jalr_target	: std_logic_vector(31 downto 0);
signal s_branch_target	: std_logic_vector(31 downto 0);
signal s_jump_target	: std_logic_vector(31 downto 0); -- final jump target (jal vs jalr)
signal s_final_target	: std_logic_vector(31 downto 0); -- final pc target
signal s_redirect	: std_logic;

-- ── BRANCH PREDICTOR SIGNALS ─────────────────────────────────────────
-- IF-stage prediction (from sw_fetch_unit o_pred_taken output)
signal s_IF_pred_taken      : std_logic;
-- ID-stage prediction (latched through IFID register)
signal s_ID_pred_taken      : std_logic;
-- EX-stage prediction (latched through IDEX register; used for mispredict check)
signal s_EX_pred_taken      : std_logic;
-- What the branch/jump in EX actually did
signal s_actual_taken       : std_logic;
-- '1' when the instruction in EX is a JALR (dynamic target — BTB can't be trusted)
signal s_EX_is_jalr         : std_logic;
-- '1' when EX outcome differs from what was predicted in IF
signal s_mispredict         : std_logic;
-- Recovery target: actual target if should-have-jumped, else EX_PC+4
signal s_mispredict_target  : std_logic_vector(31 downto 0);
-- '1' when a branch or jump instruction is in the EX stage
signal s_pred_update_en     : std_logic;
  
  --signal s_Flush	: std_logic; 


-- ====== PIPELINE REGISTER SIGNALS ======= --
-- ====== IF/ID REGISTER SIGNALS==========
signal s_ID_PC		: std_logic_vector(31 downto 0); 
signal s_ID_Instr	: std_logic_vector(31 downto 0); 
signal s_ID_PC_Plus4	: std_logic_vector(31 downto 0);

signal s_ID_opcode	: std_logic_vector(6 downto 0); 
signal s_ID_rs1_addr	: std_logic_vector(4 downto 0); 
signal s_ID_rs2_addr	: std_logic_vector(4 downto 0); 
signal s_ID_rd_addr	: std_logic_vector(4 downto 0); 
signal s_ID_funct3	: std_logic_vector(2 downto 0); 

-- ========= ID/EX REGISTER SIGNALS======== 

signal s_EX_PC		: std_logic_vector(31 downto 0);
signal s_EX_Instr	: std_logic_vector(31 downto 0);
signal s_EX_PC_Plus4	: std_logic_vector(31 downto 0);
signal s_EX_rs1_out	: std_logic_vector(31 downto 0);
signal s_EX_rs2_out	: std_logic_vector(31 downto 0);
signal s_EX_ImmGen	: std_logic_vector(31 downto 0);
signal s_EX_Jump	: std_logic;
signal s_EX_Branch	: std_logic;
signal s_EX_PC_SRC	: std_logic;
signal s_EX_ALUSrc	: std_logic;
signal s_EX_ALUCtrl	: std_logic_vector(3 downto 0);
signal s_EX_isLUI	: std_logic;
signal s_EX_isAUIPC	: std_logic;
signal s_EX_MemWrite	: std_logic;
signal s_EX_MemRead	: std_logic;
signal s_EX_RegWrite	: std_logic;
signal s_EX_MemToReg	: std_logic_vector(1 downto 0);
signal s_EX_Halt	: std_logic; 


signal s_EX_funct3	: std_logic_vector(2 downto 0);
signal s_EX_funct7_5	: std_logic;
signal s_EX_rd_addr	: std_logic_vector(4 downto 0);
signal s_EX_rs1_addr	: std_logic_vector(4 downto 0);
signal s_EX_rs2_addr	: std_logic_vector(4 downto 0);



-- ========= EX/MEM REGISTER SIGNALS======== 

signal s_MEM_PC		: std_logic_vector(31 downto 0);
signal s_MEM_Instr	: std_logic_vector(31 downto 0);
signal s_MEM_PC_Plus4	: std_logic_vector(31 downto 0);



signal s_MEM_BranchTaken : std_logic; 
signal s_MEM_rs1_out	: std_logic_vector(31 downto 0);
signal s_MEM_Jump	: std_logic; 
signal s_MEM_PC_SRC	: std_logic; 
signal s_MEM_Branch	: std_logic; 
signal s_MEM_ImmGen	: std_logic_vector(31 downto 0);


signal s_MEM_ALU_Result	: std_logic_vector(31 downto 0);
signal s_MEM_rs2_out	: std_logic_vector(31 downto 0);
signal s_MEM_rd_addr	: std_logic_vector(4 downto 0);
signal s_MEM_MemWrite	: std_logic;
signal s_MEM_MemRead	: std_logic;
signal s_MEM_RegWrite	: std_logic;
signal s_MEM_MemToReg	: std_logic_vector(1 downto 0);

signal s_MEM_Halt	: std_logic; 

signal s_MEM_funct3	: std_logic_vector(2 downto 0);

-- ========= MEM/WB REGISTER SIGNALS======== 

signal s_WB_PC		: std_logic_vector(31 downto 0);
signal s_WB_PC_Plus4	: std_logic_vector(31 downto 0);
signal s_WB_ALU_Result	: std_logic_vector(31 downto 0);
signal s_WB_DMemOut	: std_logic_vector(31 downto 0);
signal s_WB_rd_addr	: std_logic_vector(4 downto 0);
signal s_WB_RegWrite	: std_logic;
signal s_WB_MemToReg	: std_logic_vector(1 downto 0);
signal s_WB_Halt	: std_logic; 


  -- First mux: select between rs1 and PC (for AUIPC)
  -- Second mux: select between that and zero (for LUI)

  signal s_ALU_A_auipc : std_logic_vector(N-1 downto 0);
  signal s_ALU_A       : std_logic_vector(N-1 downto 0);
  signal s_isLUI       : std_logic;
  signal s_isAUIPC     : std_logic;
  


--- ===== FORWARDING SIGNALS ===== --- 
  signal s_fwd_A	: std_logic_vector(1 downto 0);
  signal s_fwd_B	: std_logic_vector(1 downto 0);

  signal s_ALU_A_fwd	: std_logic_vector(31 downto 0);
  signal s_ALU_B_fwd	: std_logic_vector(31 downto 0);

  signal s_EX_rs1_fwd	: std_logic_vector(31 downto 0);
  signal s_EX_rs2_fwd	: std_logic_vector(31 downto 0);

-- ========= END OF ADDED SIGNALS ===== -- 



 -- ======= ADDED COMPONENTS ========= --
component fetch_unit is
  generic(N : integer := 32);
  port(iCLK            		: in std_logic;
       iRST            		: in std_logic;
       rs1			: in std_logic_vector(31 downto 0); 
       PC_SRC			: in std_logic; 
       JUMP			: in std_logic; 
       BRANCH			: in std_logic; 
       ZERO			: in std_logic; 
       immediate_generate 	: in std_logic_vector(31 downto 0);
       PC_ID			: in std_logic_vector(31 downto 0);
       o_PC         		: out std_logic_vector(31 downto 0); --THIS WIRES DIRECTLY TO SKELETON s_PC! 
       Pc_plus4			: out std_logic_vector(31 downto 0)); 
end  component;

component mux2t1 is 
Port( i_D0, i_D1, i_S : in std_logic; 
	o_O : out std_logic);

end component; 


component mux2t1_N is
  generic(N : integer := 32); -- Generic of type integer for input/output data width. Default value is 16.
  port(i_S          : in std_logic;
       i_D0         : in std_logic_vector(N-1 downto 0);
       i_D1         : in std_logic_vector(N-1 downto 0);
       o_O          : out std_logic_vector(N-1 downto 0));

end component;

component sc_processor_control_unit is
  port(
    i_opcode   : in  std_logic_vector(6 downto 0);  -- instruction [6:0]

    o_ALUSrc   : out std_logic;                      -- 0=rs2  1=imm
    o_MemToReg : out std_logic_vector(1 downto 0);                      -- 0=ALU  1=mem
    o_RegWrite : out std_logic;                      -- 1=write rd
    o_MemRead  : out std_logic;                      -- 1=read  data mem
    o_MemWrite : out std_logic;                      -- 1=write data mem
    o_Branch   : out std_logic;                      -- 1=conditional branch
    o_Jump     : out std_logic;                      -- 1=unconditional jump (jal/jalr)
    o_PC_SRC   : out std_logic; 		     -- 1= use rs1 as PC base (JALR only) 
    o_ALUOp    : out std_logic_vector(2 downto 0);   -- ALU operation selector
    o_Halt     : out std_logic		     	     -- 1=halt (WFI instruction)
  );
end component;

component sc_processor_alu_control is
  port(
    i_ALUOp   : in  std_logic_vector(2 downto 0);  -- from control_unit
    i_funct3  : in  std_logic_vector(2 downto 0);  -- instruction [14:12]
    i_funct7_5: in  std_logic;                      -- instruction bit 30 (funct7[5])

    o_ALUCtrl : out std_logic_vector(3 downto 0)   -- to ALU operation select
  );
end component;

component branch_resolver is

port(i_funct3		: in std_logic_vector(2 downto 0); 
     i_Zero		: in std_logic; 
     i_SLT		: in std_logic_vector(31 downto 0); 
     i_SLTU		: in std_logic_vector(31 downto 0); 
     o_taken		: out std_logic
);

end component;


component register_file is

port(clk 		: in std_logic; 
     reset		: in std_logic; 
     write_enable	: in std_logic; 
     rd_address		: in std_logic_vector(4 downto 0); 
     rd_data		: in std_logic_vector(31 downto 0); 
     rs1_address	: in std_logic_vector(4 downto 0); 
     rs2_address	: in std_logic_vector(4 downto 0); 
     rs1_out		: out std_logic_vector(31 downto 0); 
     rs2_out		: out std_logic_vector(31 downto 0)
);

end component;

component immediate_generator is
  port(
    instruction        : in  std_logic_vector(31 downto 0);
    immediate_generate : out std_logic_vector(31 downto 0)
  );
end component;

component alu_32 is
  port(
    i_A      : in  std_logic_vector(31 downto 0);  -- operand A (rs1, PC, or zero -- see datapath)
    i_B      : in  std_logic_vector(31 downto 0);  -- operand B (rs2 or imm)
    i_ALUCtrl: in  std_logic_vector(3  downto 0);  -- from alu_control.vhd

    o_Result : out std_logic_vector(31 downto 0);
    o_Zero   : out std_logic;                       -- 1 when result == 0
    o_SLT    : out std_logic_vector(31 downto 0);   -- exposed for branch logic (resolver) 
    o_SLTU   : out std_logic_vector(31 downto 0)    -- exposed for branch logic (resolver)
  );
end component;


-- ========== PIPELINE REGISTER COMPONENTS ========= -- 

component IFID_PipelineRegister is 

port(	iCLK: 		in std_logic;
	iRST: 		in std_logic;
	iWE:		in std_logic;
	iFLUSH:		in std_logic; 

	--IF INPUTS 
	IF_PC:	  	in std_logic_vector(31 downto 0); 
	IF_Instr: 	in std_logic_vector(31 downto 0); 
	IF_PC_Plus4:	in std_logic_vector(31 downto 0);

	--ID OUTPUTS
	ID_PC:		out std_logic_vector(31 downto 0); 
	ID_Instr: 	out std_logic_vector(31 downto 0);
	ID_PC_Plus4:	out std_logic_vector(31 downto 0)
); 

end component;

component IDEX_PipelineRegister is 

port(	iCLK: 		in std_logic;
	iRST: 		in std_logic;
	iWE:		in std_logic;  -- for stall control?
	iFLUSH: 		in std_logic; 

	--ID INPUTS: datapath 
	ID_PC:	  		in std_logic_vector(31 downto 0); 
	ID_Instr: 		in std_logic_vector(31 downto 0); 
	ID_PC_Plus4:		in std_logic_vector(31 downto 0);

	ID_rs1_out:		in std_logic_vector(31 downto 0); 
	ID_rs2_out:		in std_logic_vector(31 downto 0);

	ID_ImmGen:		in std_logic_vector(31 downto 0); 

	--ID INPUTS: control signals, ex-stage consumers
	ID_ALUSrc:		in std_logic;
	ID_ALUCtrl:		in std_logic_vector(3 downto 0);
	ID_isLUI:		in std_logic;
	ID_isAUIPC:		in std_logic;
	ID_Jump:		in std_logic;
	ID_Branch:		in std_logic;
	ID_PC_SRC:		in std_logic;

	--ID INPUTS: control signals, mem-stage consumers --> passing through 
	ID_MemWrite:		in std_logic;
	ID_MemRead:		in std_logic;
	
	--ID INPUTS: control signals, wb-stage consumers --> passing through 
	ID_RegWrite:		in std_logic;
	ID_MemToReg:		in std_logic_vector(1 downto 0);
	ID_Halt:		in std_logic; 
	

	--EX OUTPUTS: datapath 
	EX_PC:			out std_logic_vector(31 downto 0); 
	EX_Instr:		out std_logic_vector(31 downto 0);
	EX_PC_Plus4:		out std_logic_vector(31 downto 0);
	EX_rs1_out:		out std_logic_vector(31 downto 0);
	EX_rs2_out:		out std_logic_vector(31 downto 0);
	EX_ImmGen:		out std_logic_vector(31 downto 0);


	--EX OUTPUTS: control signals 
	EX_ALUSrc:		out std_logic;
	EX_ALUCtrl:		out std_logic_vector(3 downto 0);
	EX_isLUI:		out std_logic;
	EX_isAUIPC:		out std_logic;
	EX_MemWrite:		out std_logic;
	EX_MemRead:		out std_logic;
	EX_RegWrite:		out std_logic;
	EX_MemToReg:		out std_logic_vector(1 downto 0);
	EX_Jump:		out std_logic;
	EX_Branch:		out std_logic;
	EX_PC_SRC:		out std_logic;
	EX_Halt:		out std_logic 
); 

end component;

component EXMEM_PipelineRegister is 

port(	iCLK: 		in std_logic;
	iRST: 		in std_logic;
	iWE:		in std_logic;  -- for stall control?
	iFLUSH: 		in std_logic; 

	--EX INPUTS: datapath 
	EX_PC:	  		in std_logic_vector(31 downto 0); 
	EX_Instr: 		in std_logic_vector(31 downto 0); 
	EX_PC_Plus4:		in std_logic_vector(31 downto 0);

	--EX_Branch_Taken:	in std_logic; --see what Jay does with branch resolver repositioning 
	EX_ALU_Result:		in std_logic_vector(31 downto 0);
	EX_rs2_out:		in std_logic_vector(31 downto 0);
	EX_rd_addr:		in std_logic_vector(4 downto 0);

	--EX INPUTS: control signals, mem-stage consumers --> 
	EX_MemWrite:		in std_logic;
	EX_MemRead:		in std_logic;
	

	--mem-stage consumers, fetch unit signals --
	EX_BranchTaken:		in std_logic;
	EX_Jump: 		in std_logic; 
	EX_PC_SRC:		in std_logic; 
	EX_rs1_out:		in std_logic_vector(31 downto 0); 
	EX_ImmGen:		in std_logic_vector(31 downto 0); 
	EX_Branch:		in std_logic; 
	

	
	--EX INPUTS: control signals, wb-stage consumers --> passing through 
	EX_RegWrite:		in std_logic;
	EX_MemToReg:		in std_logic_vector(1 downto 0);
	EX_Halt:		in std_logic; 


	--MEM OUTPUTS: datapath 
	MEM_PC:			out std_logic_vector(31 downto 0); 
	MEM_Instr:		out std_logic_vector(31 downto 0);
	MEM_PC_Plus4:		out std_logic_vector(31 downto 0);
	
	--MEM OUTPUTS: fetching 
	MEM_BranchTaken:	out std_logic;
	MEM_Jump:		out std_logic;
	MEM_PC_SRC:		out std_logic; 
	MEM_rs1_out:		out std_logic_vector(31 downto 0);
	MEM_Branch:		out std_logic;
	MEM_ImmGen:		out std_logic_vector(31 downto 0);

	--
	MEM_ALU_Result:		out std_logic_vector(31 downto 0);
	MEM_rs2_out:		out std_logic_vector(31 downto 0);
	MEM_rd_addr:		out std_logic_vector(4 downto 0);

	--MEM OUTPUTS: control
	MEM_Halt:		out std_logic; 
	MEM_MemWrite:		out std_logic;
	MEM_MemRead:		out std_logic;
	MEM_RegWrite:		out std_logic;
	MEM_MemToReg:		out std_logic_vector(1 downto 0)

); 

end component;



component MEMWB_PipelineRegister is 

	port(	iCLK: 		in std_logic;
		iRST: 		in std_logic;
		iWE:		in std_logic;  -- for stall control?
		--iFLUSH -- for squashing flushing eventually?

		--MEM INPUTS: datapath 
		MEM_PC:	  		in std_logic_vector(31 downto 0); 
		MEM_PC_Plus4:		in std_logic_vector(31 downto 0);
		MEM_ALU_Result:		in std_logic_vector(31 downto 0);
		MEM_DMemOut:		in std_logic_vector(31 downto 0);
		MEM_rd_addr:		in std_logic_vector(4 downto 0);
	


	
		--MEM INPUTS: control signals, wb-stage consumers --> 
		MEM_RegWrite:		in std_logic;
		MEM_MemToReg:		in std_logic_vector(1 downto 0);
		MEM_Halt:		in std_logic; 

		--WB OUTPUTS: datapath 
		WB_PC:			out std_logic_vector(31 downto 0); 
		WB_PC_Plus4:		out std_logic_vector(31 downto 0);
		WB_ALU_Result:		out std_logic_vector(31 downto 0);
		WB_DMemOut:		out std_logic_vector(31 downto 0);
		WB_rd_addr:		out std_logic_vector(4 downto 0);

		--WB OUTPUTS: control
		WB_Halt:		out std_logic; 
		WB_RegWrite:		out std_logic;
		WB_MemToReg:		out std_logic_vector(1 downto 0)

	); 

end component;

component carry_lookahead_adderN is
  generic(N : integer := 32); -- Generic of type integer for input/output data width. Default value is 16.
  port(A         : in std_logic_vector(N-1 downto 0);
       B         : in std_logic_vector(N-1 downto 0);
       Cin       : in std_logic;
       Sum	 : out std_logic_vector(N-1 downto 0);  
       Cout      : out std_logic); 

end component;

component sw_fetch_unit is
  generic(N : integer := 32);
  port(iCLK            : in  std_logic;
       iRST            : in  std_logic;
       i_target        : in  std_logic_vector(31 downto 0);
       i_taken         : in  std_logic;
       i_stall         : in  std_logic;
       o_PC            : out std_logic_vector(31 downto 0);
       Pc_plus4        : out std_logic_vector(31 downto 0));
end  component;


component hazard_detection_unit is 
	port(
		EX_MemRead	: in std_logic;
		EX_rd_addr	: in std_logic_vector(4 downto 0);
		ID_rs1_addr	: in std_logic_vector(4 downto 0);
		ID_rs2_addr	: in std_logic_vector(4 downto 0);
		o_stall		: out std_logic 
	);

end component;

component mux3t1_N is
    generic(N : integer := 32);
    port(i_S  : in  std_logic_vector(1 downto 0);
         i_D0 : in  std_logic_vector(N-1 downto 0);
         i_D1 : in  std_logic_vector(N-1 downto 0);
         i_D2 : in  std_logic_vector(N-1 downto 0);
         o_O  : out std_logic_vector(N-1 downto 0));
end component;


component forwarding_unit is
  port( -- From ID/EX 
	EX_rs1_addr:		in std_logic_vector(4 downto 0);
	EX_rs2_addr:		in std_logic_vector(4 downto 0);
	
	-- From EX/MEM
	MEM_RegWrite:		in std_logic;
	MEM_rd_addr:		in std_logic_vector(4 downto 0);
	
	-- From MEM/WB 
	WB_RegWrite:		in std_logic; 
	WB_rd_addr:		in std_logic_vector(4 downto 0); 

	o_fwd_A:		out std_logic_vector(1 downto 0); -- associated with ALU A
	o_fwd_B:		out std_logic_vector(1 downto 0)
	); 
end  component;


-- ========= END OF ADDED COMPONENTS ===== -- 


begin

  -- all the necessary concurrent signals? --  
  s_Ovfl 		<= '0'; -- RISC-V does not have hardware overflow detection.
  s_RegWrAddr		<= s_WB_rd_addr; 
  s_RegWr		<= s_WB_RegWrite; 
  s_DMemWr		<= s_MEM_MemWrite; 	--PIPELINE CHANGE 
  s_DMemAddr		<= s_MEM_ALU_Result;	--PIPELINE CHANGE 
  s_DMemData		<= s_MEM_rs2_out;	--call me mario with all these pipes
  oALUOut               <= s_ALUOut;
  oHalt                  <= s_Halt;

 -- s_WE_gated <= iWE or iFLUSH; 

  -- ── What actually happened in EX stage ─────────────────────────────
  s_actual_taken  <= (s_EX_Jump) or (s_EX_Branch and s_EX_BranchTaken);

  -- NO BRANCH PREDICTOR IN THIS TOOLFLOW: statically predict NOT-taken.
  -- Without this driver the signal is 'U' in simulation, which turns
  -- s_mispredict/s_redirect into 'X' and corrupts the PC on the first
  -- cycle after reset. With '0', s_mispredict = s_actual_taken, i.e. we
  -- redirect on every actually-taken branch/jump — correct behavior for
  -- a predict-not-taken pipeline.
  s_EX_pred_taken <= '0';

  -- JALR has a dynamic target; BTB may store a stale return address.
  -- Force a mispredict whenever JALR was predicted taken so we always
  -- redirect to the freshly-computed rs1+imm target.
  s_EX_is_jalr    <= '1' when s_EX_Instr(6 downto 0) = "1100111" else '0';
  s_mispredict    <= (s_actual_taken xor s_EX_pred_taken)
                     or (s_EX_is_jalr and s_EX_pred_taken);

  -- ── Mispredict recovery target ──────────────────────────────────────
  -- If actually taken: redirect to the real computed target.
  -- If not taken:      redirect to the sequential address after the branch.
  s_mispredict_target <= s_final_target when s_actual_taken = '1' else s_EX_PC_Plus4;

  -- ── Redirect / flush ────────────────────────────────────────────────
  -- s_redirect now fires ONLY on mispredictions, not on every taken branch.
  -- Correctly predicted taken branches cost 0 extra cycles.
  s_redirect <= s_mispredict;

  -- ── BHT/BTB update enable ───────────────────────────────────────────
  s_pred_update_en <= s_EX_Branch or s_EX_Jump;

  s_isLUI   <= '1' when s_ID_Instr(6 downto 0) = "0110111" else '0';
  s_isAUIPC <= '1' when s_ID_Instr(6 downto 0) = "0010111" else '0';
  s_Halt    <= s_WB_Halt; --Pipeline halt 
  --s_Flush	<= (s_MEM_BranchTaken and s_MEM_Branch) or s_MEM_Jump; 
  s_flush_IFID	<= s_redirect; 
  s_flush_IDEX	<= s_stall or s_redirect;
  s_stall_n	<= not s_stall; 



 --====PIPELINE CONCURRENT SIGNAL SLICING! ==== -- 

 --ID OUTPUT SLICING 
 
 s_ID_opcode	<= s_ID_Instr(6 downto 0); 
 s_ID_rs1_addr	<= s_ID_Instr(19 downto 15); 
 s_ID_rs2_addr	<= s_ID_Instr(24 downto 20); 
 s_ID_rd_addr	<= s_ID_Instr(11 downto 7); 
 s_ID_funct3	<= s_ID_Instr(14 downto 12); 

--EX OUTPUT SLICING

s_EX_funct3	<= s_EX_Instr(14 downto 12);
s_EX_funct7_5	<= s_EX_Instr(30);
s_EX_rd_addr	<= s_EX_Instr(11 downto 7);
s_EX_rs1_addr	<= s_EX_Instr(19 downto 15); -- FOR FORWARDING!
s_EX_rs2_addr	<= s_EX_Instr(24 downto 20); -- FOR FORWARDING!


--MEM OUTPUT SLICING
s_MEM_funct3	<= s_MEM_Instr(14 downto 12);

--WB OUTPUT SLICING?





--this halt decode is a good instinct when we implement ecall and other things, but for now we should stick to control's decode --shawn 
-- s_Halt <= '1' when (s_Inst(6 downto 0) = "1110011" and
  --                  s_Inst(31 downto 20) = "000100000101")
  --        else '0';
  
  -- Load data sign/zero extender
-- Load data sign/zero extender (process statement)
process(s_DMemOut, s_MEM_funct3, s_MEM_ALU_Result)
    variable v_byte : std_logic_vector(7 downto 0);
    variable v_half : std_logic_vector(15 downto 0);
begin
    -- select byte using address[1:0]
    case s_MEM_ALU_Result(1 downto 0) is
        when "00"   => v_byte := s_DMemOut(7  downto 0);
        when "01"   => v_byte := s_DMemOut(15 downto 8);
        when "10"   => v_byte := s_DMemOut(23 downto 16);
        when others => v_byte := s_DMemOut(31 downto 24);
    end case;

    -- select halfword using address[1]
    if s_MEM_ALU_Result(1) = '0' then
        v_half := s_DMemOut(15 downto 0);
    else
        v_half := s_DMemOut(31 downto 16);
    end if;

    -- sign/zero extend
    case s_MEM_funct3 is
        when "000"  => s_LoadData <= (31 downto 8  => v_byte(7))  & v_byte;
        when "001"  => s_LoadData <= (31 downto 16 => v_half(15)) & v_half;
        when "010"  => s_LoadData <= s_DMemOut;
        when "100"  => s_LoadData <= (31 downto 8  => '0') & v_byte;
        when "101"  => s_LoadData <= (31 downto 16 => '0') & v_half;
        when others => s_LoadData <= s_DMemOut;
    end case;
end process;

  -- TODO: This is required to be your final input to your instruction memory. 
  --This provides a feasible method to externally load the memory module which means that the synthesis tool must assume it knows nothing about the values stored in the instruction memory. If this is not included, much, if not all of the design is optimized out because the synthesis tool will believe the memory to be all zeros.
  with iInstLd select
    s_IMemAddr <= s_PC when '0',
      iInstAddr when others;


 --MUX FOR WHAT GOES TO RD DATA-- 
with s_WB_MemToReg select
  s_RegWrData <= s_WB_ALU_Result   	when "00",
                 s_WB_DMemOut  		when "01",  -- ? changed
                 s_WB_PC_Plus4 		when "10",
                 s_WB_ALU_Result   	when others;


 
  IMem: mem
    generic map(ADDR_WIDTH => ADDR_WIDTH,
                DATA_WIDTH => N,
                INIT_FILE  => "imem.mif"
                )
    port map(clk  => iCLK,
             addr => s_IMemAddr(11 downto 2),
             data => iInstExt,
             we   => iInstLd,
             q    => s_Inst);
  
  DMem: mem
    generic map(ADDR_WIDTH => ADDR_WIDTH,
                DATA_WIDTH => N)
    port map(clk  => iCLK,
             addr => s_DMemAddr(11 downto 2), -- pipelining, bayBEE!
             data => s_DMemData,
             we   => s_DMemWr,
             q    => s_DMemOut);

 

  -- TODO: Implement the rest of your processor below this comment! 


  -- ===== FETCH UNIT ==== -- 

--F_UNIT: fetch_unit
  --generic map( N => N)
  --port map(	iCLK            	=> iCLK,
		--iRST            	=> iRST,
		--rs1			=> s_rs1_data, -- straight up register file output, change for hw pipepline 
       		--PC_SRC			=> s_PC_SRC, -- from proc_control
       		--JUMP			=> s_Jump,   -- from proc_control
       		--BRANCH	        	=> s_EX_Branch,
       		--ZERO			=> s_EX_BranchTaken,
       		--immediate_generate	=> s_immediate,
		--PC_ID			=> s_ID_PC,
       		--o_PC         		=> s_PC,
       		--Pc_plus4		=> s_PC_plus4
	-- ); 

F_UNIT_SW: sw_fetch_unit
  generic map(N => 32)
  port map(iCLK     => iCLK,
           iRST     => iRST,
           i_target => s_final_target,
           i_taken  => s_redirect,
           i_stall  => s_stall,
           o_PC     => s_PC,
           Pc_plus4 => s_PC_plus4);

-- ====== JUMP CALCULATION ====== -- 

JAL_ADDER: carry_lookahead_adderN
	generic map(N => 32)
	port map(A	=> s_EX_PC,
		 B	=> s_EX_ImmGen,
		 Cin	=> '0',
		 Sum	=> s_jal_target,
		 Cout	=> open);

JALR_ADDER: carry_lookahead_adderN
	generic map(N => 32)
	port map(A	=> s_EX_rs1_fwd,
		 B	=> s_EX_ImmGen,
		 Cin	=> '0',
		 Sum	=> s_jalr_target,
		 Cout	=> open);

BRANCH_ADDER: carry_lookahead_adderN
	generic map(N => 32)
	port map(A	=> s_EX_PC,
		 B	=> s_EX_ImmGen,
		 Cin	=> '0',
		 Sum	=> s_branch_target,
		 Cout	=> open);


JUMP_TARGET_MUX: mux2t1_N
	generic map(N => 32)
	port map(i_S 	=> s_EX_PC_SRC,
		 i_D0	=> s_jal_target,
		 i_D1	=> s_jalr_target,
		 o_O	=> s_jump_target);

BRANCH_JUMP_MUX: mux2t1_N
	generic map(N => 32)
	port map(i_S 	=> s_EX_Jump,
		 i_D0	=> s_branch_target,
		 i_D1	=> s_jump_target,
		 o_O	=> s_final_target);

-- ====== IF/ID PIPELINE REGISTER ======= -- 
IFID_REG: IFID_PipelineRegister
	port map(
		iCLK		=> iCLK,
		iRST		=> iRST,
		iWE		=> s_stall_n, 
		iFLUSH		=> s_flush_IFID,
		IF_PC		=> s_PC,
		IF_Instr	=> s_Inst,
		IF_PC_Plus4	=> s_PC_plus4,
		
		ID_PC		=> s_ID_PC,
		ID_Instr	=> s_ID_Instr,
		ID_PC_Plus4	=> s_ID_PC_Plus4);


-- ====== ID/EX PIPELINE REGISTER ===== -- 
IDEX_REG: IDEX_PipelineRegister
	port map(
		iCLK		=> iCLK,
		iRST		=> iRST,
		iWE		=> s_stall_n, --stalling 
		iFLUSH		=> s_flush_IDEX,
		--datapath inputs--

		ID_PC		=> s_ID_PC, 		-- from IF/ID register output
		ID_Instr	=> s_ID_Instr,		-- from IF/ID register output
		ID_PC_Plus4	=> s_ID_PC_Plus4,	-- from IF/ID register output
		ID_rs1_out	=> s_rs1_data,		-- from register file
		ID_rs2_out	=> s_rs2_data,		-- from register file
		ID_ImmGen	=> s_immediate, 	-- from immediate generator 

		--Control inputs

		ID_ALUSrc	=> s_ALUSrc,		-- from proc control
		ID_ALUCtrl	=> s_ALUCtrl,		-- from alu control
		ID_isLUI	=> s_isLUI,		-- from concurrent assign
		ID_isAUIPC	=> s_isAUIPC,		-- from concurrent assign
		ID_Jump		=> s_Jump,		-- from proc control
		ID_Branch	=> s_Branch,		-- from proc control
		ID_PC_SRC	=> s_PC_SRC,		-- from proc control
		ID_MemWrite	=> s_MemWrite, 		-- from proc control
		ID_MemRead	=> s_MemRead,		-- from proc control
		ID_RegWrite	=> s_RegWrite,  	-- from proc control
		ID_MemToReg	=> s_MemToReg,  	-- from proc control
		ID_Halt		=> s_HaltCtrl,		-- from proc control

		--Datapath outputs
		EX_PC		=> s_EX_PC,
		EX_Instr	=> s_EX_Instr,
		EX_PC_Plus4	=> s_EX_PC_Plus4,
		EX_rs1_out	=> s_EX_rs1_out,
		EX_rs2_out	=> s_EX_rs2_out,
		EX_ImmGen	=> s_EX_ImmGen,
		
		--Control outputs
		EX_ALUSrc	=> s_EX_ALUSrc,
		EX_ALUCtrl	=> s_EX_ALUCtrl,
		EX_isLUI	=> s_EX_isLUI,
		EX_isAUIPC	=> s_EX_isAUIPC,
		EX_Jump		=> s_EX_Jump,
		EX_Branch	=> s_EX_Branch,
		EX_PC_SRC	=> s_EX_PC_SRC,
		EX_MemWrite	=> s_EX_MemWrite,
		EX_MemRead	=> s_EX_MemRead,
		EX_RegWrite	=> s_EX_RegWrite,
		EX_MemToReg	=> s_EX_MemToReg,
		EX_Halt		=> s_EX_Halt
	);




-- ======= HAZARD DETECTION ========== --
HAZARD_DETECT:	hazard_detection_unit
	port map(
		EX_MemRead	=> s_EX_MemRead,
		EX_rd_addr	=> s_EX_rd_addr,
		ID_rs1_addr	=> s_ID_rs1_addr,
		ID_rs2_addr	=> s_ID_rs2_addr,
		o_stall		=> s_stall
	);




-- ======= FORWARDING UNIT ========= -- 
FORWARDING: 	forwarding_unit
	port map(
		EX_rs1_addr	=> s_EX_rs1_addr, -- from ID/EX slice,
		EX_rs2_addr	=> s_EX_rs2_addr, -- from ID/EX 
		MEM_RegWrite	=> s_MEM_RegWrite, -- from EX/MEM output
		MEM_rd_addr	=> s_MEM_rd_addr,  -- from EX/MEM
		WB_RegWrite	=> s_WB_RegWrite,  -- from MEM/WB
		WB_rd_addr	=> s_WB_rd_addr,   -- from MEM/WB
		o_fwd_A		=> s_fwd_A,
		o_fwd_B		=> s_fwd_B);

 -- ====== CONTROLS ====== -- 
MAIN_CONTROL: sc_processor_control_unit
  port map(
    		i_opcode   		=> s_ID_Instr(6 downto 0),
    		o_ALUSrc   		=> s_ALUSrc,
    		o_MemToReg 		=> s_MemToReg,                     
    		o_RegWrite 		=> s_RegWrite,
    		o_MemRead  		=> s_MemRead,
    		o_MemWrite 		=> s_MemWrite,
    		o_Branch   		=> s_Branch,
    		o_Jump     		=> s_Jump,
    		o_PC_SRC   		=> s_PC_SRC,
    		o_ALUOp    		=> s_ALUOp,
    		o_Halt                  => s_HaltCtrl
  );	

ALU_CONTROL: sc_processor_alu_control
  port map(
    		i_ALUOp   		=> s_ALUOp,
    		i_funct3  		=> s_ID_Instr(14 downto 12), 
    		i_funct7_5 		=> s_ID_Instr(30),                     -- instruction bit 30 (funct7[5])

    		o_ALUCtrl		=>  s_ALUCtrl
  );

-- ======= IMMEDIATE ===== -- 
IMM_GEN: immediate_generator
	port map(
		instruction	 	=> s_ID_Instr,
		immediate_generate	=> s_immediate
		); 


-- ======= REGISTER FILE ===== -- 
REG_FILE: register_file
	port map(
		clk		=> iCLK,
		reset		=> iRST,
		write_enable	=> s_RegWr,
		rd_address	=> s_RegWrAddr,
		rd_data		=> s_RegWrData,
		rs1_address	=> s_ID_Instr(19 downto 15), -- direct instruction bits
		rs2_address	=> s_ID_Instr(24 downto 20), -- direct instruction bits
		rs1_out		=> s_rs1_data,
		rs2_out		=> s_rs2_data
		); 






-- ========= EX/MEM PIPELINE REGISTER ======= -- 

EXMEM_REG: EXMEM_PipelineRegister
	port map(
		iCLK		=> iCLK,
		iRST		=> iRST,
		iWE		=> '1', --stalling
		iFLUSH		=> s_redirect, -- changed from s_redirect when implementing forwarding - shawn 
		--datapath inputs--
		EX_PC		=> s_EX_PC,		--from ID/EX output
		EX_Instr	=> s_EX_Instr,		--from ID/EX output
		EX_PC_Plus4	=> s_EX_PC_Plus4, 	--from ID/EX output
		EX_ALU_Result	=> s_ALUOut,		--from ALU output
		EX_rs2_out	=> s_EX_rs2_fwd,	-- changed for forwarding
		EX_rd_addr	=> s_EX_rd_addr,	--from ID/EX slice
		
		--Control inputs-- 
		EX_MemWrite	=> s_EX_MemWrite,	--from ID/EX output
		EX_MemRead	=> s_EX_MemRead,	--from ID/EX output
		EX_RegWrite	=> s_EX_RegWrite,	--from ID/EX output
		EX_MemToReg	=> s_EX_MemToReg,	--from ID/EX output

		--Fetching inputs--
		EX_BranchTaken	=> s_EX_BranchTaken,	--from the branch resolver
		EX_Jump		=> s_EX_Jump,		--from ID/EX output
		EX_PC_SRC	=> s_EX_PC_SRC,		--from ID/EX output
		EX_rs1_out	=> s_EX_rs1_out,	--from ID/EX output
		EX_Branch	=> s_EX_Branch,		--from ID/EX output
		EX_ImmGen	=> s_EX_ImmGen, 	--from ID/EX output
		EX_Halt		=> s_EX_Halt,		--from ID/EX output
		
		--Datapath outputs

		MEM_PC		=> s_MEM_PC,
		MEM_Instr	=> s_MEM_Instr,
		MEM_PC_Plus4	=> s_MEM_PC_Plus4,
		MEM_ALU_Result	=> s_MEM_ALU_Result,
		MEM_rs2_out	=> s_MEM_rs2_out,
		MEM_rd_addr	=> s_MEM_rd_addr,
		



		MEM_BranchTaken => s_MEM_BranchTaken,
		MEM_Jump	=> s_MEM_Jump,
		MEM_PC_SRC	=> s_MEM_PC_SRC,
		MEM_rs1_out	=> s_MEM_rs1_out,
		MEM_Branch	=> s_MEM_Branch, 
		MEM_ImmGen	=> s_MEM_ImmGen,
		
		--Control outputs
		
		MEM_MemWrite	=> s_MEM_MemWrite,
		MEM_MemRead	=> s_MEM_MemRead,
		MEM_RegWrite	=> s_MEM_RegWrite,
		MEM_MemToReg	=> s_MEM_MemToReg,
		MEM_Halt	=> s_MEM_Halt
		);

-- ====== B MUX ====== -- 
B_SRC_MUX: mux2t1_N
	generic map(N => N) 
	Port map( i_D0		=>  s_EX_rs2_fwd,
		  i_D1		=>  s_EX_ImmGen,
		  i_S		=>  s_EX_ALUSrc,
		  o_O		=>  s_B_ALU_choice
		);




-- ======= A MUX ====== -- 
 AUIPC_MUX: mux2t1_N
  	generic map(N => N)
  	port map(
    		i_S  => s_EX_isAUIPC,
    		i_D0 => s_EX_rs1_fwd,
    		i_D1 => s_EX_PC,
    		o_O  => s_ALU_A_auipc
  		);


LUI_MUX: mux2t1_N
  	generic map(N => N)
  	port map(
    		i_S  => s_EX_isLUI,
    		i_D0 => s_ALU_A_auipc,
    		i_D1 => (others => '0'),
    		o_O  => s_ALU_A
  		);

FWD_MUX_A: mux3t1_N
	generic map(N => 32)
	port map(
		i_S	=> s_fwd_A,
		i_D0	=> s_EX_rs1_out, 	-- "00" means no forwarding
		i_D1	=> s_MEM_ALU_Result, 	-- "01" means forwarding from MEM
		i_D2	=> s_RegWrData,		-- "10" means forwarding from WB
		o_O	=> s_EX_rs1_fwd		-- goes into AUIPC_MUX
	);

FWD_MUX_B: mux3t1_N
	generic map(N => 32)
	port map(
		i_S	=> s_fwd_B,
		i_D0	=> s_EX_rs2_out,
		i_D1	=> s_MEM_ALU_Result,
		i_D2	=> s_RegWrData,
		o_O	=> s_EX_rs2_fwd
	);
-- ====== ALU ======== -- 
ALU: alu_32
  port map(
    		i_A      	=> s_ALU_A, 
   		i_B		=> s_B_ALU_choice,
    		i_ALUCtrl	=> s_EX_ALUCtrl,  

    		o_Result	=> s_ALUOut,
    		o_Zero   	=> s_ALU_Zero,
    		o_SLT    	=> s_ALU_SLT,
    		o_SLTU   	=> s_ALU_SLTU
  );



-- ====== BRANCH RESOLVER ===== -- 
BRANCH_COND: branch_resolver
  port map(
	i_funct3	=> s_EX_funct3,
	i_Zero		=> s_ALU_Zero,
	i_SLT		=> s_ALU_SLT,
	i_SLTU		=> s_ALU_SLTU,
	o_taken		=> s_EX_BranchTaken
	); 



-- ====== MEM/WB PIPELINE REGISTER ====== -- 
MEMWB_REG:	MEMWB_PipelineRegister
	port map(
		iCLK		=> iCLK,
		iRST		=> iRST,
		iWE		=> '1', --stalling
		
		--Datapath inputs--
		MEM_PC		=> 	s_MEM_PC, 	--EX/MEM output
		MEM_PC_Plus4	=>	s_MEM_PC_Plus4,	--EX/MEM output
		MEM_ALU_Result	=> 	s_MEM_ALU_Result, -- EX/MEM output
		MEM_DMemOut	=> 	s_LoadData,	--from LoadDataMUX
		MEM_rd_addr	=> 	s_MEM_rd_addr,	--EX/MEM output
		
		--Control inputs--
		MEM_RegWrite	=>	s_MEM_RegWrite,	--EX/MEM output
		MEM_MemToReg	=> 	s_MEM_MemToReg,	--EX/MEM output
		MEM_Halt	=>	s_MEM_Halt,	--EX/MEM output
		
		--Datapath outputs--
		WB_PC		=>	s_WB_PC,
		WB_PC_Plus4	=>	s_WB_PC_Plus4,
		WB_ALU_Result	=> 	s_WB_ALU_Result,
		WB_DMemOut	=>	s_WB_DMemOut,
		WB_rd_addr	=>	s_WB_rd_addr,

		--Control outputs--
		WB_Halt		=>      s_WB_Halt,
		WB_RegWrite	=>	s_WB_RegWrite,
		WB_MemToReg	=>	s_WB_MemToReg
		);


end structure;
