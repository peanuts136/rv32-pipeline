package rv32_pkg;
//Package will define the constants, ALU operation names, branch operation names, writebacks, control signals, and pipeline registers
//Other files will access it using "import rv32_pkg::*"
    localparam logic [31:0] RESET_VECTOR = 32'h0000_0000; //Address from where CPU will fetch instructions after reset
    localparam logic [31:0] NOP = 32'h0000_0013; //Identical to addi x0, x0, 0, since writes to x0 should be discarded, basically changes nothing

    //ALU operation should be performing
    typedef enum logic [3:0] {
        ALU_ADD, ALU_SUB, ALU_AND, ALU_OR, ALU_XOR, ALU_SLT, ALU_SLTU, ALU_SLL, ALU_SRL, ALU_SRA
    } alu_op_e;

    //Defines branch behavior
    typedef enum logic[2:0]{
        BR_NONE, BR_EQ, BR_NE, BR_LT, BR_GE, BR_LTU, BR_GEU, BR_JUMP
    } branch_op_e;

    //Writeback source that will be written to rd
    typedef enum logic [1:0]{
        WB_ALU, WB_MEM, WB_PC4
    } wb_sel_e;

    //Bundles all decoded control signals
    //Core carries one control structure "control_t ctrl", accessible using "ctrl.reg_write"
    //Packed allows us to store as pipeline register, allowing operations such as dec_ctrl = '0 which sets everything to 0
    typedef struct packed {
        logic legal;
        logic uses_rs1;
        logic uses_rs2;
        logic reg_write;
        logic alu_a_pc; //1=use instruction PC, else use rs1 or 0
        logic alu_b_imm; //1=use imm, 0=rs2
        logic mem_read; //for load
        logic mem_write; //for store
        logic jalr; //1 = target + imm with bit 0=0, 0=PC+imm
        logic [2:0] funct3; //original instructions funct3 field will be retained b/c need to distinguished word, byte, half word, etc
        //The enum fields
        alu_op_e alu_op;
        branch_op_e branch_op;
        wb_sel_e wb_sel;
    } control_t;

    //The following are the pipeline registers which can hold information
    //Values are introduced as necessary
    typedef struct packed {
        logic valid; //Real instruction?
        logic [31:0] pc;
        logic [31:0] pc4;
        logic [31:0] instr; //Encoded instruction
    } if_id_t;

    //Holds everything the EX stage will need 
    typedef struct packed {
        logic valid;
        logic [31:0] pc;
        logic [31:0] pc4;
        logic [31:0] instr;

        logic [4:0]  rs1;
        logic [4:0]  rs2;
        logic [4:0]  rd;
        logic [31:0] rs1_value;
        logic [31:0] rs2_value;
        logic [31:0] imm;
        control_t ctrl; //Control bundle
    } id_ex_t;

    typedef struct packed {
        logic  valid;
        logic [31:0] pc;
        logic [31:0] pc4;
        logic [31:0] instr;
        logic [4:0]  rd;

        logic [31:0] alu_result;
        logic [31:0] store_data; //Final forwared data

        //The control signals needed for MEM/WB is carried forward, complete control_t is not necessary
        logic  reg_write; //Whether to write into rd
        logic  mem_read;
        logic  mem_write;
        logic [2:0] funct3;
        wb_sel_e wb_sel;
    } ex_mem_t;

    typedef struct packed {
        logic valid;
        logic [31:0] pc;
        logic [31:0] instr;
        logic [4:0]  rd;
        logic [31:0] wb_value; //Final value selected from ALU, memory data, or PC4
        logic reg_write; //Whether to write into rd
    } mem_wb_t;
endpackage
