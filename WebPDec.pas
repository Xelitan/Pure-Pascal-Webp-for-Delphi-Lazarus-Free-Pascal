unit WebPDec;


////////////////////////////////////////////////////////////////////////////////
//                                                                            //
// Description:	WEBP port (decoder only)                                      //
// Version:	0.3                                                           //
// Date:	28-MAY-2026                                                   //
// License:     MIT                                                           //
// Target:	Win64, Free Pascal, Delphi                                    //
// Copyright:	(c) 2026 Xelitan.com.                                         //
//		All rights reserved.                                          //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////

{$IFDEF FPC}
  {$MODE DELPHI}{$H+}{$inline on}
{$ENDIF}
{$R-}{$Q-}

interface

// All output buffers allocated with GetMem; caller frees with FreeMem.
function WebPGetInfo(Data: PByte; DataSize: NativeUInt;
  out Width, Height: Integer): Boolean;
function WebPDecodeRGBA(Data: PByte; DataSize: NativeUInt;
  out Width, Height: Integer): PByte;
function WebPDecodeARGB(Data: PByte; DataSize: NativeUInt;
  out Width, Height: Integer): PByte;
function WebPDecodeBGRA(Data: PByte; DataSize: NativeUInt;
  out Width, Height: Integer): PByte;
function WebPDecodeRGB(Data: PByte; DataSize: NativeUInt;
  out Width, Height: Integer): PByte;
function WebPDecodeBGR(Data: PByte; DataSize: NativeUInt;
  out Width, Height: Integer): PByte;

implementation
{$POINTERMATH ON}

uses SysUtils;

// ============================================================
// TYPES
// ============================================================
type
  {$IF NOT DECLARED(PInt16)}
  PInt16  = ^Int16;
  {$IFEND}
  {$IF NOT DECLARED(PUInt32)}
  PUInt32 = ^UInt32;
  {$IFEND}
  TCSMode = (csmRGBA, csmARGB, csmBGRA, csmRGB, csmBGR);

// ============================================================
// CONSTANTS
// ============================================================
const
  BPS      = 32;                    // YUV reconstruction buffer stride
  YUV_SIZE = BPS * 17 + BPS * 9;   // = 832
  Y_OFF    = BPS * 1 + 8;           // = 40
  U_OFF    = Y_OFF + BPS * 16 + BPS * 1;  // = 584
  V_OFF    = U_OFF + 16;            // = 600

  NUM_MB_SEGMENTS       = 4;
  NUM_TYPES             = 4;
  NUM_BANDS             = 8;
  NUM_CTX               = 3;
  NUM_PROBAS            = 11;
  MB_FEATURE_TREE_PROBS = 3;
  NUM_REF_LF_DELTAS     = 4;
  NUM_MODE_LF_DELTAS    = 4;
  MAX_NUM_PARTITIONS    = 8;

  // 4x4 intra block modes
  B_DC_PRED = 0;  B_TM_PRED = 1;  B_VE_PRED = 2;  B_HE_PRED = 3;
  B_RD_PRED = 4;  B_VR_PRED = 5;  B_LD_PRED = 6;  B_VL_PRED = 7;
  B_HD_PRED = 8;  B_HU_PRED = 9;
  NUM_BMODES = 10;

  // 16x16 / UV intra modes — MUST match B_*_PRED values so that
  // I16x16 mode values stored as I4x4 top/left context use correct kBModesProba rows.
  // C: DC_PRED=B_DC_PRED=0, TM_PRED=B_TM_PRED=1, V_PRED=B_VE_PRED=2, H_PRED=B_HE_PRED=3
  DC_PRED = 0;  TM_PRED = 1;  V_PRED = 2;  H_PRED = 3;  B_PRED = 4;

  FIXED_TABLE_SIZE = 630 * 3 + 410;  // = 2300  (VP8L Huffman)

// ============================================================
// VP8 PROBABILITY / QUANTIZATION TABLES
// ============================================================
const
  CoeffsProba0: array[0..3,0..7,0..2,0..10] of Byte = (
  ((( 128,128,128,128,128,128,128,128,128,128,128),
    ( 128,128,128,128,128,128,128,128,128,128,128),
    ( 128,128,128,128,128,128,128,128,128,128,128)),
   (( 253,136,254,255,228,219,128,128,128,128,128),
    ( 189,129,242,255,227,213,255,219,128,128,128),
    ( 106,126,227,252,214,209,255,255,128,128,128)),
   ((   1, 98,248,255,236,226,255,255,128,128,128),
    ( 181,133,238,254,221,234,255,154,128,128,128),
    (  78,134,202,247,198,180,255,219,128,128,128)),
   ((   1,185,249,255,243,255,128,128,128,128,128),
    ( 184,150,247,255,236,224,128,128,128,128,128),
    (  77,110,216,255,236,230,128,128,128,128,128)),
   ((   1,101,251,255,241,255,128,128,128,128,128),
    ( 170,139,241,252,236,209,255,255,128,128,128),
    (  37,116,196,243,228,255,255,255,128,128,128)),
   ((   1,204,254,255,245,255,128,128,128,128,128),
    ( 207,160,250,255,238,128,128,128,128,128,128),
    ( 102,103,231,255,211,171,128,128,128,128,128)),
   ((   1,152,252,255,240,255,128,128,128,128,128),
    ( 177,135,243,255,234,225,128,128,128,128,128),
    (  80,129,211,255,194,224,128,128,128,128,128)),
   ((   1,  1,255,128,128,128,128,128,128,128,128),
    ( 246,  1,255,128,128,128,128,128,128,128,128),
    ( 255,128,128,128,128,128,128,128,128,128,128))),
  ((( 198, 35,237,223,193,187,162,160,145,155, 62),
    ( 131, 45,198,221,172,176,220,157,252,221,  1),
    (  68, 47,146,208,149,167,221,162,255,223,128)),
   ((   1,149,241,255,221,224,255,255,128,128,128),
    ( 184,141,234,253,222,220,255,199,128,128,128),
    (  81, 99,181,242,176,190,249,202,255,255,128)),
   ((   1,129,232,253,214,197,242,196,255,255,128),
    (  99,121,210,250,201,198,255,202,128,128,128),
    (  23, 91,163,242,170,187,247,210,255,255,128)),
   ((   1,200,246,255,234,255,128,128,128,128,128),
    ( 109,178,241,255,231,245,255,255,128,128,128),
    (  44,130,201,253,205,192,255,255,128,128,128)),
   ((   1,132,239,251,219,209,255,165,128,128,128),
    (  94,136,225,251,218,190,255,255,128,128,128),
    (  22,100,174,245,186,161,255,199,128,128,128)),
   ((   1,182,249,255,232,235,128,128,128,128,128),
    ( 124,143,241,255,227,234,128,128,128,128,128),
    (  35, 77,181,251,193,211,255,205,128,128,128)),
   ((   1,157,247,255,236,231,255,255,128,128,128),
    ( 121,141,235,255,225,227,255,255,128,128,128),
    (  45, 99,188,251,195,217,255,224,128,128,128)),
   ((   1,  1,251,255,213,255,128,128,128,128,128),
    ( 203,  1,248,255,255,128,128,128,128,128,128),
    ( 137,  1,177,255,224,255,128,128,128,128,128))),
  ((( 253,  9,248,251,207,208,255,192,128,128,128),
    ( 175, 13,224,243,193,185,249,198,255,255,128),
    (  73, 17,171,221,161,179,236,167,255,234,128)),
   ((   1, 95,247,253,212,183,255,255,128,128,128),
    ( 239, 90,244,250,211,209,255,255,128,128,128),
    ( 155, 77,195,248,188,195,255,255,128,128,128)),
   ((   1, 24,239,251,218,219,255,205,128,128,128),
    ( 201, 51,219,255,196,186,128,128,128,128,128),
    (  69, 46,190,239,201,218,255,228,128,128,128)),
   ((   1,191,251,255,255,128,128,128,128,128,128),
    ( 223,165,249,255,213,255,128,128,128,128,128),
    ( 141,124,248,255,255,128,128,128,128,128,128)),
   ((   1, 16,248,255,255,128,128,128,128,128,128),
    ( 190, 36,230,255,236,255,128,128,128,128,128),
    ( 149,  1,255,128,128,128,128,128,128,128,128)),
   ((   1,226,255,128,128,128,128,128,128,128,128),
    ( 247,192,255,128,128,128,128,128,128,128,128),
    ( 240,128,255,128,128,128,128,128,128,128,128)),
   ((   1,134,252,255,255,128,128,128,128,128,128),
    ( 213, 62,250,255,255,128,128,128,128,128,128),
    (  55, 93,255,128,128,128,128,128,128,128,128)),
   (( 128,128,128,128,128,128,128,128,128,128,128),
    ( 128,128,128,128,128,128,128,128,128,128,128),
    ( 128,128,128,128,128,128,128,128,128,128,128))),
  ((( 202, 24,213,235,186,191,220,160,240,175,255),
    ( 126, 38,182,232,169,184,228,174,255,187,128),
    (  61, 46,138,219,151,178,240,170,255,216,128)),
   ((   1,112,230,250,199,191,247,159,255,255,128),
    ( 166,109,228,252,211,215,255,174,128,128,128),
    (  39, 77,162,232,172,180,245,178,255,255,128)),
   ((   1, 52,220,246,198,199,249,220,255,255,128),
    ( 124, 74,191,243,183,193,250,221,255,255,128),
    (  24, 71,130,219,154,170,243,182,255,255,128)),
   ((   1,182,225,249,219,240,255,224,128,128,128),
    ( 149,150,226,252,216,205,255,171,128,128,128),
    (  28,108,170,242,183,194,254,223,255,255,128)),
   ((   1, 81,230,252,204,203,255,192,128,128,128),
    ( 123,102,209,247,188,196,255,233,128,128,128),
    (  20, 95,153,243,164,173,255,203,128,128,128)),
   ((   1,222,248,255,216,213,128,128,128,128,128),
    ( 168,175,246,252,235,205,255,255,128,128,128),
    (  47,116,215,255,211,212,255,255,128,128,128)),
   ((   1,121,236,253,212,214,255,255,128,128,128),
    ( 141, 84,213,252,201,202,255,219,128,128,128),
    (  42, 80,160,240,162,185,255,205,128,128,128)),
   ((   1,  1,255,128,128,128,128,128,128,128,128),
    ( 244,  1,255,128,128,128,128,128,128,128,128),
    ( 238,  1,255,128,128,128,128,128,128,128,128)))
  );

  CoeffsUpdateProba: array[0..3,0..7,0..2,0..10] of Byte = (
  (((255,255,255,255,255,255,255,255,255,255,255),
    (255,255,255,255,255,255,255,255,255,255,255),
    (255,255,255,255,255,255,255,255,255,255,255)),
   ((176,246,255,255,255,255,255,255,255,255,255),
    (223,241,252,255,255,255,255,255,255,255,255),
    (249,253,253,255,255,255,255,255,255,255,255)),
   ((255,244,252,255,255,255,255,255,255,255,255),
    (234,254,254,255,255,255,255,255,255,255,255),
    (253,255,255,255,255,255,255,255,255,255,255)),
   ((255,246,254,255,255,255,255,255,255,255,255),
    (239,253,254,255,255,255,255,255,255,255,255),
    (254,255,254,255,255,255,255,255,255,255,255)),
   ((255,248,254,255,255,255,255,255,255,255,255),
    (251,255,254,255,255,255,255,255,255,255,255),
    (255,255,255,255,255,255,255,255,255,255,255)),
   ((255,253,254,255,255,255,255,255,255,255,255),
    (251,254,254,255,255,255,255,255,255,255,255),
    (254,255,254,255,255,255,255,255,255,255,255)),
   ((255,254,253,255,254,255,255,255,255,255,255),
    (250,255,254,255,254,255,255,255,255,255,255),
    (254,255,255,255,255,255,255,255,255,255,255)),
   ((255,255,255,255,255,255,255,255,255,255,255),
    (255,255,255,255,255,255,255,255,255,255,255),
    (255,255,255,255,255,255,255,255,255,255,255))),
  (((217,255,255,255,255,255,255,255,255,255,255),
    (225,252,241,253,255,255,254,255,255,255,255),
    (234,250,241,250,253,255,253,254,255,255,255)),
   ((255,254,255,255,255,255,255,255,255,255,255),
    (223,254,254,255,255,255,255,255,255,255,255),
    (238,253,254,254,255,255,255,255,255,255,255)),
   ((255,248,254,255,255,255,255,255,255,255,255),
    (249,254,255,255,255,255,255,255,255,255,255),
    (255,255,255,255,255,255,255,255,255,255,255)),
   ((255,253,255,255,255,255,255,255,255,255,255),
    (247,254,255,255,255,255,255,255,255,255,255),
    (255,255,255,255,255,255,255,255,255,255,255)),
   ((255,253,254,255,255,255,255,255,255,255,255),
    (252,255,255,255,255,255,255,255,255,255,255),
    (255,255,255,255,255,255,255,255,255,255,255)),
   ((255,254,254,255,255,255,255,255,255,255,255),
    (253,255,255,255,255,255,255,255,255,255,255),
    (255,255,255,255,255,255,255,255,255,255,255)),
   ((255,254,253,255,255,255,255,255,255,255,255),
    (250,255,255,255,255,255,255,255,255,255,255),
    (254,255,255,255,255,255,255,255,255,255,255)),
   ((255,255,255,255,255,255,255,255,255,255,255),
    (255,255,255,255,255,255,255,255,255,255,255),
    (255,255,255,255,255,255,255,255,255,255,255))),
  (((186,251,250,255,255,255,255,255,255,255,255),
    (234,251,244,254,255,255,255,255,255,255,255),
    (251,251,243,253,254,255,254,255,255,255,255)),
   ((255,253,254,255,255,255,255,255,255,255,255),
    (236,253,254,255,255,255,255,255,255,255,255),
    (251,253,253,254,254,255,255,255,255,255,255)),
   ((255,254,254,255,255,255,255,255,255,255,255),
    (254,254,254,255,255,255,255,255,255,255,255),
    (255,255,255,255,255,255,255,255,255,255,255)),
   ((255,254,255,255,255,255,255,255,255,255,255),
    (254,254,255,255,255,255,255,255,255,255,255),
    (254,255,255,255,255,255,255,255,255,255,255)),
   ((255,255,255,255,255,255,255,255,255,255,255),
    (254,255,255,255,255,255,255,255,255,255,255),
    (255,255,255,255,255,255,255,255,255,255,255)),
   ((255,255,255,255,255,255,255,255,255,255,255),
    (255,255,255,255,255,255,255,255,255,255,255),
    (255,255,255,255,255,255,255,255,255,255,255)),
   ((255,255,255,255,255,255,255,255,255,255,255),
    (255,255,255,255,255,255,255,255,255,255,255),
    (255,255,255,255,255,255,255,255,255,255,255)),
   ((255,255,255,255,255,255,255,255,255,255,255),
    (255,255,255,255,255,255,255,255,255,255,255),
    (255,255,255,255,255,255,255,255,255,255,255))),
  (((248,255,255,255,255,255,255,255,255,255,255),
    (250,254,252,254,255,255,255,255,255,255,255),
    (248,254,249,253,255,255,255,255,255,255,255)),
   ((255,253,253,255,255,255,255,255,255,255,255),
    (246,253,253,255,255,255,255,255,255,255,255),
    (252,254,251,254,254,255,255,255,255,255,255)),
   ((255,254,252,255,255,255,255,255,255,255,255),
    (248,254,253,255,255,255,255,255,255,255,255),
    (253,255,254,254,255,255,255,255,255,255,255)),
   ((255,251,254,255,255,255,255,255,255,255,255),
    (245,251,254,255,255,255,255,255,255,255,255),
    (253,253,254,255,255,255,255,255,255,255,255)),
   ((255,251,253,255,255,255,255,255,255,255,255),
    (252,253,254,255,255,255,255,255,255,255,255),
    (255,254,255,255,255,255,255,255,255,255,255)),
   ((255,252,255,255,255,255,255,255,255,255,255),
    (249,255,254,255,255,255,255,255,255,255,255),
    (255,255,254,255,255,255,255,255,255,255,255)),
   ((255,255,253,255,255,255,255,255,255,255,255),
    (250,255,255,255,255,255,255,255,255,255,255),
    (255,255,255,255,255,255,255,255,255,255,255)),
   ((255,255,255,255,255,255,255,255,255,255,255),
    (254,255,255,255,255,255,255,255,255,255,255),
    (255,255,255,255,255,255,255,255,255,255,255)))
  );

  kBands: array[0..16] of Byte =
    (0,1,2,3,6,4,5,6,6,6,6,6,6,6,6,7,0);

  kBModesProba: array[0..NUM_BMODES-1,0..NUM_BMODES-1,0..NUM_BMODES-2] of Byte = (
  (( 231,120, 48, 89,115,113,120,152,112),
   ( 152,179, 64,126,170,118, 46, 70, 95),
   ( 175, 69,143, 80, 85, 82, 72,155,103),
   (  56, 58, 10,171,218,189, 17, 13,152),
   ( 114, 26, 17,163, 44,195, 21, 10,173),
   ( 121, 24, 80,195, 26, 62, 44, 64, 85),
   ( 144, 71, 10, 38,171,213,144, 34, 26),
   ( 170, 46, 55, 19,136,160, 33,206, 71),
   (  63, 20,  8,114,114,208, 12,  9,226),
   (  81, 40, 11, 96,182, 84, 29, 16, 36)),
  (( 134,183, 89,137, 98,101,106,165,148),
   (  72,187,100,130,157,111, 32, 75, 80),
   (  66,102,167, 99, 74, 62, 40,234,128),
   (  41, 53,  9,178,241,141, 26,  8,107),
   (  74, 43, 26,146, 73,166, 49, 23,157),
   (  65, 38,105,160, 51, 52, 31,115,128),
   ( 104, 79, 12, 27,217,255, 87, 17,  7),
   (  87, 68, 71, 44,114, 51, 15,186, 23),
   (  47, 41, 14,110,182,183, 21, 17,194),
   (  66, 45, 25,102,197,189, 23, 18, 22)),
  ((  88, 88,147,150, 42, 46, 45,196,205),
   (  43, 97,183,117, 85, 38, 35,179, 61),
   (  39, 53,200, 87, 26, 21, 43,232,171),
   (  56, 34, 51,104,114,102, 29, 93, 77),
   (  39, 28, 85,171, 58,165, 90, 98, 64),
   (  34, 22,116,206, 23, 34, 43,166, 73),
   ( 107, 54, 32, 26, 51,  1, 81, 43, 31),
   (  68, 25,106, 22, 64,171, 36,225,114),
   (  34, 19, 21,102,132,188, 16, 76,124),
   (  62, 18, 78, 95, 85, 57, 50, 48, 51)),
  (( 193,101, 35,159,215,111, 89, 46,111),
   (  60,148, 31,172,219,228, 21, 18,111),
   ( 112,113, 77, 85,179,255, 38,120,114),
   (  40, 42,  1,196,245,209, 10, 25,109),
   (  88, 43, 29,140,166,213, 37, 43,154),
   (  61, 63, 30,155, 67, 45, 68,  1,209),
   ( 100, 80,  8, 43,154,  1, 51, 26, 71),
   ( 142, 78, 78, 16,255,128, 34,197,171),
   (  41, 40,  5,102,211,183,  4,  1,221),
   (  51, 50, 17,168,209,192, 23, 25, 82)),
  (( 138, 31, 36,171, 27,166, 38, 44,229),
   (  67, 87, 58,169, 82,115, 26, 59,179),
   (  63, 59, 90,180, 59,166, 93, 73,154),
   (  40, 40, 21,116,143,209, 34, 39,175),
   (  47, 15, 16,183, 34,223, 49, 45,183),
   (  46, 17, 33,183,  6, 98, 15, 32,183),
   (  57, 46, 22, 24,128,  1, 54, 17, 37),
   (  65, 32, 73,115, 28,128, 23,128,205),
   (  40,  3,  9,115, 51,192, 18,  6,223),
   (  87, 37,  9,115, 59, 77, 64, 21, 47)),
  (( 104, 55, 44,218,  9, 54, 53,130,226),
   (  64, 90, 70,205, 40, 41, 23, 26, 57),
   (  54, 57,112,184,  5, 41, 38,166,213),
   (  30, 34, 26,133,152,116, 10, 32,134),
   (  39, 19, 53,221, 26,114, 32, 73,255),
   (  31,  9, 65,234,  2, 15,  1,118, 73),
   (  75, 32, 12, 51,192,255,160, 43, 51),
   (  88, 31, 35, 67,102, 85, 55,186, 85),
   (  56, 21, 23,111, 59,205, 45, 37,192),
   (  55, 38, 70,124, 73,102,  1, 34, 98)),
  (( 125, 98, 42, 88,104, 85,117,175, 82),
   (  95, 84, 53, 89,128,100,113,101, 45),
   (  75, 79,123, 47, 51,128, 81,171,  1),
   (  57, 17,  5, 71,102, 57, 53, 41, 49),
   (  38, 33, 13,121, 57, 73, 26,  1, 85),
   (  41, 10, 67,138, 77,110, 90, 47,114),
   ( 115, 21,  2, 10,102,255,166, 23,  6),
   ( 101, 29, 16, 10, 85,128,101,196, 26),
   (  57, 18, 10,102,102,213, 34, 20, 43),
   ( 117, 20, 15, 36,163,128, 68,  1, 26)),
  (( 102, 61, 71, 37, 34, 53, 31,243,192),
   (  69, 60, 71, 38, 73,119, 28,222, 37),
   (  68, 45,128, 34,  1, 47, 11,245,171),
   (  62, 17, 19, 70,146, 85, 55, 62, 70),
   (  37, 43, 37,154,100,163, 85,160,  1),
   (  63,  9, 92,136, 28, 64, 32,201, 85),
   (  75, 15,  9,  9, 64,255,184,119, 16),
   (  86,  6, 28,  5, 64,255, 25,248,  1),
   (  56,  8, 17,132,137,255, 55,116,128),
   (  58, 15, 20, 82,135, 57, 26,121, 40)),
  (( 164, 50, 31,137,154,133, 25, 35,218),
   (  51,103, 44,131,131,123, 31,  6,158),
   (  86, 40, 64,135,148,224, 45,183,128),
   (  22, 26, 17,131,240,154, 14,  1,209),
   (  45, 16, 21, 91, 64,222,  7,  1,197),
   (  56, 21, 39,155, 60,138, 23,102,213),
   (  83, 12, 13, 54,192,255, 68, 47, 28),
   (  85, 26, 85, 85,128,128, 32,146,171),
   (  18, 11,  7, 63,144,171,  4,  4,246),
   (  35, 27, 10,146,174,171, 12, 26,128)),
  (( 190, 80, 35, 99,180, 80,126, 54, 45),
   (  85,126, 47, 87,176, 51, 41, 20, 32),
   ( 101, 75,128,139,118,146,116,128, 85),
   (  56, 41, 15,176,236, 85, 37,  9, 62),
   (  71, 30, 17,119,118,255, 17, 18,138),
   ( 101, 38, 60,138, 55, 70, 43, 26,142),
   ( 146, 36, 19, 30,171,255, 97, 27, 20),
   ( 138, 45, 61, 62,219,  1, 81,188, 64),
   (  32, 41, 20,117,151,142, 20, 21,163),
   ( 112, 19, 12, 61,195,128, 48,  4, 24))
  );

  kDcTable: array[0..127] of Byte = (
    4,  5,  6,  7,  8,  9, 10, 10,
   11, 12, 13, 14, 15, 16, 17, 17,
   18, 19, 20, 20, 21, 21, 22, 22,
   23, 23, 24, 25, 25, 26, 27, 28,
   29, 30, 31, 32, 33, 34, 35, 36,
   37, 37, 38, 39, 40, 41, 42, 43,
   44, 45, 46, 46, 47, 48, 49, 50,
   51, 52, 53, 54, 55, 56, 57, 58,
   59, 60, 61, 62, 63, 64, 65, 66,
   67, 68, 69, 70, 71, 72, 73, 74,
   75, 76, 76, 77, 78, 79, 80, 81,
   82, 83, 84, 85, 86, 87, 88, 89,
   91, 93, 95, 96, 98,100,101,102,
  104,106,108,110,112,114,116,118,
  122,124,126,128,130,132,134,136,
  138,140,143,145,148,151,154,157);

  kAcTable: array[0..127] of Word = (
    4,  5,  6,  7,  8,  9, 10, 11,
   12, 13, 14, 15, 16, 17, 18, 19,
   20, 21, 22, 23, 24, 25, 26, 27,
   28, 29, 30, 31, 32, 33, 34, 35,
   36, 37, 38, 39, 40, 41, 42, 43,
   44, 45, 46, 47, 48, 49, 50, 51,
   52, 53, 54, 55, 56, 57, 58, 60,
   62, 64, 66, 68, 70, 72, 74, 76,
   78, 80, 82, 84, 86, 88, 90, 92,
   94, 96, 98,100,102,104,106,108,
  110,112,114,116,119,122,125,128,
  131,134,137,140,143,146,149,152,
  155,158,161,164,167,170,173,177,
  181,185,189,193,197,201,205,209,
  213,217,221,225,229,234,239,245,
  249,254,259,264,269,274,279,284);

  // Zigzag scan order for 4x4 block
  kZigzag: array[0..15] of Byte =
    (0,1,4,8, 5,2,3,6, 9,12,13,10, 7,11,14,15);

  // Byte offsets of each 4x4 sub-block in the YUV reconstruction buffer
  // BPS=32; sub-block row i starts at i*4*BPS = i*128
  kScan: array[0..15] of Integer = (
      0,  4,  8, 12,
    128,132,136,140,
    256,260,264,268,
    384,388,392,396);

  // Category probability tables for large residual values
  kCat3: array[0..3] of Byte = (173,148,140,  0);
  kCat4: array[0..4] of Byte = (176,155,140,135,  0);
  kCat5: array[0..5] of Byte = (180,157,141,134,130,  0);
  kCat6: array[0..11] of Byte = (254,254,243,230,196,177,153,140,133,130,129,0);

  // VP8L distance-to-plane offset table (kCodeToPlane[120])
  kCodeToPlane: array[0..119] of Integer = (
    $18,  $07,  $17,  $19,  $28,  $06,  $27,  $29,
    $16,  $1a,  $26,  $2a,  $38,  $05,  $37,  $39,
    $15,  $1b,  $36,  $3a,  $25,  $2b,  $48,  $04,
    $47,  $49,  $14,  $1c,  $35,  $3b,  $46,  $4a,
    $24,  $2c,  $58,  $45,  $4b,  $34,  $3c,  $03,
    $57,  $59,  $13,  $1d,  $56,  $5a,  $23,  $2d,
    $44,  $4c,  $55,  $5b,  $33,  $3d,  $68,  $02,
    $67,  $69,  $12,  $1e,  $66,  $6a,  $22,  $2e,
    $54,  $5c,  $43,  $4d,  $65,  $6b,  $32,  $3e,
    $78,  $01,  $77,  $79,  $53,  $5d,  $11,  $1f,
    $64,  $6c,  $42,  $4e,  $76,  $7a,  $21,  $2f,
    $75,  $7b,  $31,  $3f,  $63,  $6d,  $52,  $5e,
    $00,  $74,  $7c,  $41,  $4f,  $10,  $20,  $62,
    $6e,  $30,  $73,  $7d,  $51,  $5f,  $40,  $72,
    $7e,  $61,  $6f,  $50,  $71,  $7f,  $60,  $70);

  // Huffman code length reorder for VP8L canonical codes
  kCodeLengthCodeOrder: array[0..18] of Byte =
    (17,18,0,1,2,3,4,5,16,6,7,8,9,10,11,12,13,14,15);

  // Alphabet sizes for the 5 Huffman code groups in VP8L
  kAlphabetSize: array[0..4] of Integer = (280, 256, 256, 256, 40);

// ============================================================
// RECORD TYPES  (after consts so sizes are known)
// ============================================================
type
  TVP8BandProbas = record
    Probas: array[0..NUM_CTX-1, 0..NUM_PROBAS-1] of Byte;
  end;

  // One row of band-pointers (17 entries: bands 0..16, with kBands mapping)
  TBandPtrsRow = array[0..16] of ^TVP8BandProbas;

  TVP8Proba = record
    Bands:    array[0..NUM_TYPES-1, 0..NUM_BANDS-1] of TVP8BandProbas;
    BandsPtr: array[0..NUM_TYPES-1] of TBandPtrsRow;
  end;

  TVP8QuantMatrix = record
    Y1Mat:   array[0..1] of Integer;
    Y2Mat:   array[0..1] of Integer;
    UVMat:   array[0..1] of Integer;
    UVQuant: Integer;
  end;

  TVP8SegmentHeader = record
    UseSegment:    Boolean;
    UpdateMap:     Boolean;
    AbsoluteDelta: Boolean;
    Quantizer:     array[0..NUM_MB_SEGMENTS-1] of Integer;
    FilterStrength:array[0..NUM_MB_SEGMENTS-1] of Integer;
    SegProbs:      array[0..MB_FEATURE_TREE_PROBS-1] of Byte; // segment map probs
  end;

  TVP8MB = record
    NZ:   Byte;   // non-zero AC flags (Y0..Y3, U0,U1, V0,V1)
    NZDC: Byte;   // non-zero DC flags
  end;
  PVP8MB = ^TVP8MB;

  TVP8MBData = record
    Coeffs:   array[0..383] of Int16;  // 24 blocks * 16 = 384
    IsI4x4:   Boolean;
    IModes:   array[0..15] of Byte;    // per-4x4-block modes
    UVMode:   Byte;
    NonZeroY: Cardinal;
    NonZeroUV:Cardinal;
    Skip:     Boolean;
    Segment:  Byte;
  end;
  PVP8MBData = ^TVP8MBData;

  // Huffman code entry used by VP8L
  THuffmanCode = record
    Bits:  Byte;   // code length (0 = invalid)
    Value: Word;   // symbol value
  end;
  PHuffmanCode = ^THuffmanCode;

  THuffmanCode32 = record
    Bits:  Byte;
    Value: Cardinal;
  end;

// ============================================================
// HELPER FUNCTIONS
// ============================================================

// Arithmetic right shift by n bits (FPC's shr is logical/unsigned).
// Equivalent to C's (v >> n) for signed int32.
// Uses the identity: sar(v,n) = ~(~v >> n) for negative v, v>>n for positive v.
function SarI(v, n: Integer): Integer; inline;
begin
  if v >= 0 then Result := v shr n
  else Result := not (not v shr n);
end;

function Clip8b(v: Integer): Byte; inline;
begin
  if v < 0 then Result := 0
  else if v > 255 then Result := 255
  else Result := Byte(v);
end;

function ClipMax(v, M: Integer): Integer; inline;
begin
  if v < 0 then Result := 0
  else if v > M then Result := M
  else Result := v;
end;

// YUV → RGB (libwebp formulas from yuv.h)
function MultHi(v, c: Integer): Integer; inline;
begin
  Result := (v * c) shr 8;
end;

function VP8Clip8(v: Integer): Byte; inline;
// YUV_FIX2=6, YUV_MASK2=$3FFF
begin
  if (v and (not $3FFF)) = 0 then
    Result := Byte(v shr 6)
  else if v < 0 then
    Result := 0
  else
    Result := 255;
end;

function YuvToR(y, v: Integer): Byte; inline;
begin
  Result := VP8Clip8(MultHi(y, 19077) + MultHi(v, 26149) - 14234);
end;

function YuvToG(y, u, v: Integer): Byte; inline;
begin
  Result := VP8Clip8(MultHi(y, 19077) - MultHi(u, 6419) - MultHi(v, 13320) + 8708);
end;

function YuvToB(y, u: Integer): Byte; inline;
begin
  Result := VP8Clip8(MultHi(y, 19077) + MultHi(u, 33050) - 17685);
end;

// ============================================================
// VP8L BIT READER  (LSB-first, 64-bit accumulator)
// ============================================================
type
  TVP8LBitReader = record
    Val:       UInt64;
    Available: Integer;
    Buf:       PByte;
    BufEnd:    PByte;
    Eos:       Boolean;
  end;

procedure VP8LFillBitWindow(var BR: TVP8LBitReader); inline;
begin
  while (BR.Available <= 56) and (BR.Buf < BR.BufEnd) do
  begin
    BR.Val := BR.Val or (UInt64(BR.Buf^) shl BR.Available);
    Inc(BR.Buf);
    Inc(BR.Available, 8);
  end;
  if (BR.Buf >= BR.BufEnd) and (BR.Available < 0) then
    BR.Eos := True;
end;

procedure VP8LInitBitReader(var BR: TVP8LBitReader; Data: PByte; Size: NativeUInt);
begin
  BR.Val       := 0;
  BR.Available := 0;
  BR.Buf       := Data;
  BR.BufEnd    := Data + Size;
  BR.Eos       := (Size = 0);
  VP8LFillBitWindow(BR);
end;

function VP8LReadBits(var BR: TVP8LBitReader; N: Integer): Cardinal; inline;
begin
  if N = 0 then begin Result := 0; Exit; end;
  Result := Cardinal(BR.Val) and Cardinal((UInt64(1) shl N) - 1);
  BR.Val := BR.Val shr N;
  Dec(BR.Available, N);
  if BR.Available <= 32 then VP8LFillBitWindow(BR);
end;

function VP8LPeekBits(const BR: TVP8LBitReader; N: Integer): Cardinal; inline;
begin
  Result := Cardinal(BR.Val) and Cardinal((UInt64(1) shl N) - 1);
end;

// ============================================================
// VP8 BOOLEAN BIT READER  (MSB-first, range coder)
// Matches libwebp bit_reader_utils.c:
//   range starts at 254; split = (range * prob) >> 8
// ============================================================
type
  TVP8Rd = record
    Val:    UInt64;   // accumulated bit window
    Range:  UInt32;   // current range [127..254]
    Bits:   Integer;  // valid bits in Val (>= 0)
    Buf:    PByte;
    BufEnd: PByte;
    Eof:    Boolean;
  end;

procedure VP8RdLoadByte(var R: TVP8Rd); inline;
begin
  if R.Buf < R.BufEnd then
  begin
    R.Val := (R.Val shl 8) or R.Buf^;
    Inc(R.Buf);
  end else
  begin
    R.Eof := True;
    R.Val := R.Val shl 8;
  end;
  Inc(R.Bits, 8);
end;

procedure VP8RdInit(var R: TVP8Rd; Data: PByte; Size: NativeUInt);
begin
  R.Val    := 0;
  R.Range  := 254;
  R.Bits   := -8;
  R.Buf    := Data;
  R.BufEnd := Data + Size;
  R.Eof    := (Size = 0);
  VP8RdLoadByte(R);   // Bits = 0 after this
end;

function VP8RdGetBit(var R: TVP8Rd; Prob: Integer): Integer; inline;
var
  split: UInt32;
begin
  if R.Bits < 0 then VP8RdLoadByte(R);
  split := (R.Range * UInt32(Prob)) shr 8;
  if (R.Val shr R.Bits) > split then
  begin
    Dec(R.Range, split + 1);
    Dec(R.Val, UInt64(split + 1) shl R.Bits);
    Result := 1;
  end else
  begin
    R.Range := split;
    Result := 0;
  end;
  // Normalize: keep Range in [127..254]
  while R.Range < 127 do
  begin
    R.Range := R.Range * 2 + 1;
    Dec(R.Bits);
    if R.Bits < 0 then
      VP8RdLoadByte(R);
  end;
end;

function VP8RdGet(var R: TVP8Rd): Integer; inline;
begin
  Result := VP8RdGetBit(R, 128);
end;

// Specialized sign-bit read matching C's VP8GetSigned(br, v):
//   Returns v if sign=0, -v if sign=1.
//   Uses prob=128 but with the simplified update matching libwebp's VP8GetSigned.
//   Unlike VP8RdGetBit(128), this does NOT normalize Range afterward,
//   instead it unconditionally decrements Bits by 1 and sets Range |= 1.
//   The two functions diverge only for Range=254 with sign=0:
//     VP8RdGetBit gives Range=127, Bits unchanged;
//     VP8RdGetSigned gives Range=255, Bits-=1.
//   Using VP8RdGetSigned matches the C reference decoder exactly.
function VP8RdGetSigned(var R: TVP8Rd; v: Integer): Integer; inline;
var
  pos: Integer;
  split, value: UInt32;
  mask: Integer;
begin
  if R.Bits < 0 then VP8RdLoadByte(R);
  pos   := R.Bits;                              // save original Bits position
  split := R.Range shr 1;
  value := UInt32(R.Val shr pos);
  // SarI: arithmetic right shift gives 0 or -1 (FPC shr is logical → wrong)
  mask  := SarI(Integer(split) - Integer(value), 31);
  R.Bits := pos - 1;                            // decrement by 1 (may become -1)
  Inc(R.Range, UInt32(mask));                   // range-1 if bit=1 (mask=-1), range if bit=0
  R.Range := R.Range or 1;                      // always ensure lowest bit set
  Dec(R.Val, UInt64((split + 1) and UInt32(mask)) shl pos);  // use original pos, not decremented
  Result := (v xor mask) - mask;                // v if mask=0, -v if mask=-1
end;

function VP8RdGetValue(var R: TVP8Rd; N: Integer): Cardinal; inline;
var i: Integer;
begin
  Result := 0;
  for i := N - 1 downto 0 do
    if VP8RdGetBit(R, 128) <> 0 then
      Result := Result or (Cardinal(1) shl i);
end;

function VP8RdGetSignedValue(var R: TVP8Rd; N: Integer): Integer; inline;
var v: Cardinal;
begin
  v := VP8RdGetValue(R, N);
  if VP8RdGetBit(R, 128) <> 0 then
    Result := -Integer(v)
  else
    Result := Integer(v);
end;

// ============================================================
// VP8L HUFFMAN TABLE BUILDER
// Port of huffman_utils.c : BuildHuffmanTable
// ============================================================
const
  HUFF_LUT_BITS = 8;  // root table bits

type
  THuffTable = array[0..FIXED_TABLE_SIZE-1] of THuffmanCode;
  PHuffTable = ^THuffTable;

// Correct Huffman build used in VP8L decode
// Returns True on success. Builds reverse-lookup table.
function VP8LBuildHuffmanTable(
  const Lengths: array of Integer; NumSymbols: Integer;
  Table: PHuffmanCode; TableBits: Integer): Boolean;
var
  count:     array[0..16] of Integer;
  nextcode:  array[0..16] of Cardinal;
  code:      Cardinal;
  i, len:    Integer;
  entry:     THuffmanCode;
  mirror:    Cardinal;
  j, step:   Integer;
  tableSize: Integer;
begin
  Result := False;
  tableSize := 1 shl TableBits;
  FillChar(count, SizeOf(count), 0);
  for i := 0 to NumSymbols-1 do
  begin
    len := Lengths[i];
    if (len < 0) or (len > 15) then Exit;
    Inc(count[len]);
  end;
  // Assign canonical codes
  code := 0;
  nextcode[0] := 0;
  for len := 1 to 15 do
  begin
    code := (code + count[len-1]) shl 1;
    nextcode[len] := code;
  end;
  // Fill table
  for i := 0 to tableSize-1 do
  begin
    Table[i].Bits  := 0;
    Table[i].Value := $FFFF;
  end;
  for i := 0 to NumSymbols-1 do
  begin
    len := Lengths[i];
    if len = 0 then Continue;
    if len > TableBits then Continue;  // ignore overflow for now
    // Reverse the canonical code to get LSB-first lookup key
    code := nextcode[len];
    Inc(nextcode[len]);
    mirror := 0;
    for j := 0 to len-1 do
      if (code shr j) and 1 <> 0 then
        mirror := mirror or (Cardinal(1) shl (len-1-j));
    // Replicate for all suffixes
    step := 1 shl len;
    j := Integer(mirror);
    while j < tableSize do
    begin
      entry.Bits  := Byte(len);
      entry.Value := Word(i);
      Table[j]    := entry;
      Inc(j, step);
    end;
  end;
  Result := True;
end;

// Read a Huffman symbol using the lookup table
function HuffReadSymbol(var BR: TVP8LBitReader;
  const Table: PHuffmanCode; TableBits: Integer): Integer; inline;
var
  key: Cardinal;
  e:   THuffmanCode;
begin
  key := VP8LPeekBits(BR, TableBits);
  e   := Table[key];
  if e.Bits = 0 then begin Result := -1; Exit; end;
  // Consume the bits
  BR.Val := BR.Val shr e.Bits;
  Dec(BR.Available, e.Bits);
  if BR.Available <= 32 then VP8LFillBitWindow(BR);
  Result := Integer(e.Value);
end;

// ============================================================
// DECODER DATA TYPES
// ============================================================
type
  TVP8Decoder = record
    // Main bitreader (partition 0)
    BR:          TVP8Rd;
    // AC residual partition readers
    Parts:       array[0..MAX_NUM_PARTITIONS-1] of TVP8Rd;
    NumParts:    Integer;

    // Picture dimensions
    PicWidth:    Integer;
    PicHeight:   Integer;
    MbW:         Integer;   // macroblock columns
    MbH:         Integer;   // macroblock rows

    // Headers
    KeyFrame:    Boolean;
    Profile:     Integer;
    PartLen0:    Integer;   // partition 0 byte length

    // Segment
    SegHdr:      TVP8SegmentHeader;
    // Quantization matrices (one per segment)
    DQM:         array[0..NUM_MB_SEGMENTS-1] of TVP8QuantMatrix;
    // Probability tables
    Proba:       TVP8Proba;

    // Filter (skipped — just store for parsing)
    FilterSimple:   Boolean;
    FilterLevel:    Integer;
    FilterSharpness:Integer;
    UseLFDelta:     Boolean;
    RefLFDelta:     array[0..NUM_REF_LF_DELTAS-1] of Integer;
    ModeLFDelta:    array[0..NUM_MODE_LF_DELTAS-1] of Integer;

    // Decoded output row (YUV → RGB, written row by row)
    OutputMode:  TCSMode;
    OutStride:   Integer;   // bytes per output row
    OutBpp:      Integer;   // bytes per pixel

    // YUV reconstruction buffer for current MB row
    YuvBuf:      array[0..YUV_SIZE-1] of Byte;
    // Top context rows for inter-MB prediction
    YTopBuf:     PByte;   // MbW*16 bytes  (Y top row)
    UTopBuf:     PByte;   // MbW*8 bytes
    VTopBuf:     PByte;   // MbW*8 bytes
    // Per-MB NZ info (MbW+1, index 0 = left border)
    MBInfo:      PVP8MB;
    // Current MB working data
    MBData:      TVP8MBData;
    // Skip probability
    UseSkipProba: Boolean;
    SkipP:        Byte;
    // I4x4 intra-mode context
    IntraT:       PByte;          // MbW*4 bytes: top 4x4 mode per column
    IntraL:       array[0..3] of Byte;  // left 4x4 mode per row
    // Final output buffer
    OutBuf:      PByte;
  end;

// ============================================================
// VP8 HEADER PARSING
// ============================================================

procedure VP8ParseSegmentHeader(var BR: TVP8Rd; var Hdr: TVP8SegmentHeader);
var i: Integer;
begin
  Hdr.UseSegment := VP8RdGet(BR) <> 0;
  if not Hdr.UseSegment then
  begin
    Hdr.UpdateMap := False;
    Exit;
  end;
  Hdr.UpdateMap := VP8RdGet(BR) <> 0;
  // update_data flag is separate from update_map
  if VP8RdGet(BR) <> 0 then   // update data?
  begin
    Hdr.AbsoluteDelta := VP8RdGet(BR) <> 0; // 1=absolute, 0=delta (matches C absolute_delta)
    for i := 0 to NUM_MB_SEGMENTS-1 do
      if VP8RdGet(BR) <> 0 then
        Hdr.Quantizer[i] := VP8RdGetSignedValue(BR, 7)
      else
        Hdr.Quantizer[i] := 0;
    for i := 0 to NUM_MB_SEGMENTS-1 do
      if VP8RdGet(BR) <> 0 then
        Hdr.FilterStrength[i] := VP8RdGetSignedValue(BR, 6)
      else
        Hdr.FilterStrength[i] := 0;
  end;
  if Hdr.UpdateMap then
  begin
    for i := 0 to MB_FEATURE_TREE_PROBS-1 do
      if VP8RdGet(BR) <> 0 then
        Hdr.SegProbs[i] := Byte(VP8RdGetValue(BR, 8))
      else
        Hdr.SegProbs[i] := 255;
  end;
end;

procedure VP8ParseFilterHeader(var BR: TVP8Rd; var D: TVP8Decoder);
var i: Integer;
begin
  D.FilterSimple    := VP8RdGet(BR) <> 0;
  D.FilterLevel     := Integer(VP8RdGetValue(BR, 6));
  D.FilterSharpness := Integer(VP8RdGetValue(BR, 3));
  D.UseLFDelta      := VP8RdGet(BR) <> 0;
  if D.UseLFDelta and (VP8RdGet(BR) <> 0) then
  begin
    for i := 0 to NUM_REF_LF_DELTAS-1 do
      if VP8RdGet(BR) <> 0 then
        D.RefLFDelta[i] := VP8RdGetSignedValue(BR, 6);
    for i := 0 to NUM_MODE_LF_DELTAS-1 do
      if VP8RdGet(BR) <> 0 then
        D.ModeLFDelta[i] := VP8RdGetSignedValue(BR, 6);
  end;
end;

// Clip helper used in VP8ParseQuant
function QClip(v, M: Integer): Integer; inline;
begin
  if v < 0 then Result := 0
  else if v > M then Result := M
  else Result := v;
end;

procedure VP8ParseQuant(var BR: TVP8Rd; var D: TVP8Decoder);
var
  base_q0: Integer;
  dqy1_dc, dqy2_dc, dqy2_ac, dquv_dc, dquv_ac: Integer;
  i, q: Integer;
  m: ^TVP8QuantMatrix;
begin
  base_q0 := Integer(VP8RdGetValue(BR, 7));
  if VP8RdGet(BR) <> 0 then dqy1_dc  := VP8RdGetSignedValue(BR, 4) else dqy1_dc  := 0;
  if VP8RdGet(BR) <> 0 then dqy2_dc  := VP8RdGetSignedValue(BR, 4) else dqy2_dc  := 0;
  if VP8RdGet(BR) <> 0 then dqy2_ac  := VP8RdGetSignedValue(BR, 4) else dqy2_ac  := 0;
  if VP8RdGet(BR) <> 0 then dquv_dc  := VP8RdGetSignedValue(BR, 4) else dquv_dc  := 0;
  if VP8RdGet(BR) <> 0 then dquv_ac  := VP8RdGetSignedValue(BR, 4) else dquv_ac  := 0;
  for i := 0 to NUM_MB_SEGMENTS-1 do
  begin
    if D.SegHdr.UseSegment then
    begin
      q := D.SegHdr.Quantizer[i];
      if not D.SegHdr.AbsoluteDelta then Inc(q, base_q0);
    end else
    begin
      if i > 0 then begin D.DQM[i] := D.DQM[0]; Continue; end;
      q := base_q0;
    end;
    m := @D.DQM[i];
    m^.Y1Mat[0] := kDcTable[QClip(q + dqy1_dc, 127)];
    m^.Y1Mat[1] := kAcTable[QClip(q,           127)];
    m^.Y2Mat[0] := kDcTable[QClip(q + dqy2_dc, 127)] * 2;
    m^.Y2Mat[1] := (Integer(kAcTable[QClip(q + dqy2_ac, 127)]) * 101581) shr 16;
    if m^.Y2Mat[1] < 8 then m^.Y2Mat[1] := 8;
    m^.UVMat[0] := kDcTable[QClip(q + dquv_dc, 117)];   // max 117!
    m^.UVMat[1] := kAcTable[QClip(q + dquv_ac, 127)];
    m^.UVQuant  := q + dquv_ac;
  end;
end;

procedure VP8ParseProba(var BR: TVP8Rd; var D: TVP8Decoder);
var t, b, ctx, p: Integer;
begin
  // Copy defaults
  for t := 0 to NUM_TYPES-1 do
    for b := 0 to NUM_BANDS-1 do
      for ctx := 0 to NUM_CTX-1 do
        for p := 0 to NUM_PROBAS-1 do
          D.Proba.Bands[t,b].Probas[ctx,p] := CoeffsProba0[t,b,ctx,p];
  // Read updates
  for t := 0 to NUM_TYPES-1 do
    for b := 0 to NUM_BANDS-1 do
      for ctx := 0 to NUM_CTX-1 do
        for p := 0 to NUM_PROBAS-1 do
          if VP8RdGetBit(BR, CoeffsUpdateProba[t,b,ctx,p]) <> 0 then
            D.Proba.Bands[t,b].Probas[ctx,p] := Byte(VP8RdGetValue(BR, 8));
  // Build BandsPtr: BandsPtr[t][b] = @Bands[t][kBands[b]]
  for t := 0 to NUM_TYPES-1 do
    for b := 0 to 16 do
      D.Proba.BandsPtr[t][b] := @D.Proba.Bands[t, kBands[b]];
  // Skip probability (Paragraph 9.11)
  D.UseSkipProba := VP8RdGet(BR) <> 0;
  if D.UseSkipProba then
    D.SkipP := Byte(VP8RdGetValue(BR, 8));
end;

// ============================================================
// VP8 INTRA MODE PARSING
// ============================================================

function ParseIntra16Mode(var BR: TVP8Rd): Integer; inline;
begin
  // bit(156)? (bit(128)?TM:H) : (bit(163)?V:DC)
  if VP8RdGetBit(BR, 156) <> 0 then
  begin
    if VP8RdGetBit(BR, 128) <> 0 then Result := TM_PRED else Result := H_PRED;
  end else
  begin
    if VP8RdGetBit(BR, 163) <> 0 then Result := V_PRED else Result := DC_PRED;
  end;
end;

function ParseUVMode(var BR: TVP8Rd): Integer; inline;
begin
  if VP8RdGetBit(BR, 142) = 0 then Result := DC_PRED
  else if VP8RdGetBit(BR, 114) = 0 then Result := V_PRED
  else if VP8RdGetBit(BR, 183) <> 0 then Result := TM_PRED
  else Result := H_PRED;
end;

function ParseIntra4x4Mode(var BR: TVP8Rd;
  const Prob: array of Byte): Integer;
// Prob is kBModesProba[topMode][leftMode]
begin
  if VP8RdGetBit(BR, Prob[0]) = 0 then begin Result := B_DC_PRED; Exit; end;
  if VP8RdGetBit(BR, Prob[1]) = 0 then begin Result := B_TM_PRED; Exit; end;
  if VP8RdGetBit(BR, Prob[2]) = 0 then begin Result := B_VE_PRED; Exit; end;
  if VP8RdGetBit(BR, Prob[3]) = 0 then
  begin
    if VP8RdGetBit(BR, Prob[4]) = 0 then begin Result := B_HE_PRED; Exit; end;
    if VP8RdGetBit(BR, Prob[5]) = 0 then begin Result := B_RD_PRED; Exit; end;
    Result := B_VR_PRED;
  end else
  begin
    if VP8RdGetBit(BR, Prob[6]) = 0 then begin Result := B_LD_PRED; Exit; end;
    if VP8RdGetBit(BR, Prob[7]) = 0 then begin Result := B_VL_PRED; Exit; end;
    if VP8RdGetBit(BR, Prob[8]) = 0 then begin Result := B_HD_PRED; Exit; end;
    Result := B_HU_PRED;
  end;
end;

procedure VP8ParseIntraModes(var D: TVP8Decoder);
// Parses all macroblock intra prediction modes for the current frame.
// Fills D.MBData[] — called ONCE per frame before residual decoding.
// For each MB: IsI4x4, IModes[16], UVMode, Segment
var
  mbx, mby, i: Integer;
  top_modes: array[0..0] of Byte; // placeholder — real decoder needs top[] per col
  topY: PByte;  // [MbW * 16] — Y top-row modes for 4x4
  pMB: PVP8MBData;
  seg_proba: array[0..MB_FEATURE_TREE_PROBS-1] of Byte;
  seg: Integer;
  leftMode: array[0..15] of Byte; // left column 4x4 modes
  leftUV: Byte;
begin
  // For mode parsing we need a top-modes array (one 4x4 mode per top-pixel)
  // Allocate temporary: MbW * 4 bytes for top modes
  topY := AllocMem(D.MbW * 4 * SizeOf(Byte));
  FillChar(topY^, D.MbW * 4, B_DC_PRED);
  FillChar(leftMode, SizeOf(leftMode), B_DC_PRED);
  leftUV := DC_PRED;

  // Default segment proba
  seg_proba[0] := 145; seg_proba[1] := 145; seg_proba[2] := 145;

  pMB := PVP8MBData(D.OutBuf); // WRONG — need separate mode buffer
  // Actually store modes in D.MBData (only last row needed for residuals)
  // For simplicity, we parse modes and residuals together per-row in the main loop
  FreeMem(topY);
end;

// ============================================================
// VP8 RESIDUAL COEFFICIENT DECODING
// ============================================================

// Decode residual coefficients for one 4x4 block.
// Matches C GetCoeffsFast exactly:
//   p[0]=EOB check, p[1]=zero/nonzero, p[2..]=value decode
//   BandsPtr[n] already incorporates kBands mapping (DO NOT apply kBands again)
// Returns position of last non-zero coeff + 1 (i.e. 0 = all-zero)
function VP8GetCoeffsFast(var BR: TVP8Rd;
  const BandsPtr: TBandPtrsRow;
  StartCtx, First: Integer;
  Dq0, Dq1: Integer;
  Coeffs: PInt16): Integer;
var
  n, v: Integer;
  p: PByte;  // points to BandsPtr[n]^.Probas[ctx, 0]
  tab: PByte;
  bit1, bit0, cat: Integer;
begin
  // p points to the 11-byte probability row for (position n, context ctx)
  // p[0]=EOB  p[1]=zero  p[2]=v>1  p[3..]=value
  n := First;
  p := @(BandsPtr[n]^.Probas[StartCtx, 0]);

  while n < 16 do
  begin
    // p[0]: is there any non-zero coeff from position n onwards? (0 = EOB)
    if VP8RdGetBit(BR, p[0]) = 0 then
    begin
      Result := n;
      Exit;
    end;
    // p[1]: is coeff at n non-zero? (0 = this coeff is zero, advance)
    while VP8RdGetBit(BR, p[1]) = 0 do
    begin
      Inc(n);
      if n = 16 then begin Result := 16; Exit; end;
      p := @(BandsPtr[n]^.Probas[0, 0]);  // ctx=0 after zero run
    end;
    // Non-zero coeff at position n; decode absolute value using p[2..10]
    if VP8RdGetBit(BR, p[2]) = 0 then
    begin
      v := 1;
      p := @(BandsPtr[n + 1]^.Probas[1, 0]);  // ctx=1 for next
    end else
    begin
      // GetLargeValue: v > 1
      if VP8RdGetBit(BR, p[3]) = 0 then
      begin
        if VP8RdGetBit(BR, p[4]) = 0 then
          v := 2
        else
          v := 3 + VP8RdGetBit(BR, p[5]);
      end else if VP8RdGetBit(BR, p[6]) = 0 then
      begin
        if VP8RdGetBit(BR, p[7]) = 0 then
          v := 5 + VP8RdGetBit(BR, 159)
        else
        begin
          v := 7 + 2 * VP8RdGetBit(BR, 165);
          v := v + VP8RdGetBit(BR, 145);
        end;
      end else
      begin
        // Cat 3..6 using kCat3456 tables
        bit1 := VP8RdGetBit(BR, p[8]);
        bit0 := VP8RdGetBit(BR, p[9 + bit1]);
        cat  := 2 * bit1 + bit0;
        case cat of
          0: tab := @kCat3[0];
          1: tab := @kCat4[0];
          2: tab := @kCat5[0];
          3: tab := @kCat6[0];
          else tab := @kCat3[0]; // unreachable
        end;
        v := 0;
        while tab^ <> 0 do
        begin
          v := v * 2 + VP8RdGetBit(BR, tab^);
          Inc(tab);
        end;
        v := v + 3 + (8 shl cat);
      end;
      p := @(BandsPtr[n + 1]^.Probas[2, 0]);  // ctx=2 for next
    end;
    // Sign bit — use VP8RdGetSigned (matches C's VP8GetSigned) for exact range-coder state
    v := VP8RdGetSigned(BR, v);
    // Dequantize: DC (n=0) uses Dq0, AC uses Dq1
    if n = 0 then
      Coeffs[kZigzag[0]] := Int16(v * Dq0)
    else
      Coeffs[kZigzag[n]] := Int16(v * Dq1);
    Inc(n);
    if n = 16 then Break;
    // p already set to BandsPtr[n]^.Probas[ctx_new] for next iteration
  end;
  Result := n;
end;

// Forward declaration needed: VP8TransformWHT is defined in the IDCT section below
procedure VP8TransformWHT(DC: PInt16; Out16: PInt16); forward;

// Parse residuals for one macroblock. Matches C ParseResiduals exactly.
// WHT for I16x16 is applied HERE and DCs injected into Coeffs[n*16+0].
function VP8ParseResiduals(var D: TVP8Decoder; MbX: Integer;
  var Part: TVP8Rd; PartIdx: Integer): Boolean;
var
  mb:        ^TVP8MBData;
  leftMB:    PVP8MB;   // left border  = D.MBInfo (index -1)
  topMB:     PVP8MB;   // current col  = D.MBInfo + (MbX+1)
  dqm:       ^TVP8QuantMatrix;
  dcBuf:     array[0..15] of Int16;  // Y2/WHT input (separate from Coeffs)
  dst:       PInt16;
  first:     Integer;
  acBands:   ^TBandPtrsRow;
  tnz, lnz:  Byte;
  l, nz_val: Integer;
  x, y, ch:  Integer;
  ctx:       Integer;
  nzCoeffs:  Cardinal;
  nonZeroY:  Cardinal;
  nonZeroUV: Cardinal;
  outTNZ, outLNZ: Byte;
begin
  mb      := @D.MBData;
  leftMB  := D.MBInfo;                                          // dec->mb_info - 1
  topMB   := PVP8MB(NativeUInt(D.MBInfo) + (MbX+1)*SizeOf(TVP8MB));  // dec->mb_info + mb_x
  dqm     := @D.DQM[mb^.Segment];

  FillChar(mb^.Coeffs[0], SizeOf(mb^.Coeffs), 0);
  nonZeroY  := 0;
  nonZeroUV := 0;

  // === Y2 / WHT DC block (type 1), only for I16x16 ===
  if not mb^.IsI4x4 then
  begin
    FillChar(dcBuf, SizeOf(dcBuf), 0);
    ctx := Integer(topMB^.NZDC) + Integer(leftMB^.NZDC);
    nz_val := VP8GetCoeffsFast(Part, D.Proba.BandsPtr[1], ctx, 0,
                               dqm^.Y2Mat[0], dqm^.Y2Mat[1], @dcBuf[0]);
    topMB^.NZDC  := Byte(nz_val > 0);
    leftMB^.NZDC := Byte(nz_val > 0);
    if nz_val > 1 then
    begin
      // Full WHT: inject 16 DCs into each Y block's position 0
      VP8TransformWHT(@dcBuf[0], @dcBuf[0]);  // in-place into same buffer (uses tmp)
      for y := 0 to 15 do mb^.Coeffs[y * 16] := dcBuf[y];
    end else if nz_val = 1 then
    begin
      // Simplified: all 16 DCs get the same value (dc0+3)>>3 (arithmetic shift)
      nz_val := SarI(Integer(dcBuf[0]) + 3, 3);
      for y := 0 to 15 do mb^.Coeffs[y * 16] := Int16(nz_val);
    end;
    // else all zero — Coeffs already zero
    first := 1;
    acBands := @D.Proba.BandsPtr[0];
  end else
  begin
    first := 0;
    acBands := @D.Proba.BandsPtr[3];
  end;

  // === Y luma AC blocks (type 0 for I16x16, type 3 for I4x4) ===
  // Track NZ context using C's circular-buffer approach
  tnz := topMB^.NZ  and $0F;
  lnz := leftMB^.NZ and $0F;
  dst := @mb^.Coeffs[0];
  for y := 0 to 3 do
  begin
    l := lnz and 1;
    nzCoeffs := 0;
    for x := 0 to 3 do
    begin
      ctx    := l + (tnz and 1);
      nz_val := VP8GetCoeffsFast(Part, acBands^, ctx, first,
                                 dqm^.Y1Mat[0], dqm^.Y1Mat[1], dst);
      l      := Byte(nz_val > first);
      tnz    := Byte((tnz shr 1) or (l shl 7));
      // NzCodeBits: nzCoeffs = (nzCoeffs << 2) | (nz>3 ? 3 : nz>1 ? 2 : dc_nz)
      nzCoeffs := nzCoeffs shl 2;
      if nz_val > 3 then nzCoeffs := nzCoeffs or 3
      else if nz_val > 1 then nzCoeffs := nzCoeffs or 2
      else if dst[0] <> 0 then nzCoeffs := nzCoeffs or 1;
      Inc(dst, 16);
    end;
    tnz := tnz shr 4;
    lnz := Byte((lnz shr 1) or (l shl 7));
    nonZeroY := (nonZeroY shl 8) or nzCoeffs;
  end;
  outTNZ := tnz;
  outLNZ := lnz shr 4;
  mb^.NonZeroY := nonZeroY;

  // === UV chroma blocks (type 2): 2 channels × 2×2 blocks ===
  for ch := 0 to 1 do
  begin
    nzCoeffs := 0;
    tnz := topMB^.NZ  shr (4 + ch * 2);
    lnz := leftMB^.NZ shr (4 + ch * 2);
    for y := 0 to 1 do
    begin
      l := lnz and 1;
      for x := 0 to 1 do
      begin
        ctx    := l + (tnz and 1);
        nz_val := VP8GetCoeffsFast(Part, D.Proba.BandsPtr[2], ctx, 0,
                                   dqm^.UVMat[0], dqm^.UVMat[1], dst);
        l    := Byte(nz_val > 0);
        tnz  := Byte((tnz shr 1) or (l shl 3));
        nzCoeffs := nzCoeffs shl 2;
        if nz_val > 3 then nzCoeffs := nzCoeffs or 3
        else if nz_val > 1 then nzCoeffs := nzCoeffs or 2
        else if dst[0] <> 0 then nzCoeffs := nzCoeffs or 1;
        Inc(dst, 16);
      end;
      tnz := tnz shr 2;
      lnz := Byte((lnz shr 1) or (l shl 5));
    end;
    nonZeroUV := nonZeroUV or (nzCoeffs shl (4 * ch * 2));
    outTNZ    := outTNZ or Byte((tnz shl 4) shl (ch * 2));
    outLNZ    := outLNZ or Byte((lnz and $F0) shl (ch * 2));
  end;
  mb^.NonZeroUV := nonZeroUV;

  topMB^.NZ  := outTNZ;
  leftMB^.NZ := outLNZ;

  Result := (nonZeroY or nonZeroUV) = 0;  // True if skip (all zero)
end;

// ============================================================
// VP8 DSP: IDCT
// ============================================================

// 4x4 IDCT: C[16] coefficients (PInt16), adds to Pred, stores to Dst.
// Dst and Pred may be the same pointer (in-place add).
procedure VP8TransformOne(C: PInt16; Pred: PByte; Dst: PByte; Bps: Integer);
var
  tmp: array[0..3,0..3] of Integer;
  i: Integer;
  a, b, c2, d2: Integer;
  a0, a1, a2, a3: Integer;
begin
  // Vertical pass: process each column of the 4x4 coefficient block
  for i := 0 to 3 do
  begin
    a  := C[0+i] + C[8+i];
    b  := C[0+i] - C[8+i];
    // MUL1(x) = ((x*20091)>>16)+x;  MUL2(x) = (x*35468)>>16
    // Use SarI (arithmetic) because FPC shr is logical — wrong for negative values
    c2 := SarI(C[4+i] * 35468, 16) - (SarI(C[12+i] * 20091, 16) + C[12+i]);
    d2 := (SarI(C[4+i] * 20091, 16) + C[4+i]) + SarI(C[12+i] * 35468, 16);
    tmp[i,0] := a + d2;
    tmp[i,1] := b + c2;
    tmp[i,2] := b - c2;
    tmp[i,3] := a - d2;
  end;
  // Horizontal pass (process rows of tmp → output rows)
  for i := 0 to 3 do
  begin
    a  := tmp[0,i] + tmp[2,i];
    b  := tmp[0,i] - tmp[2,i];
    c2 := SarI(tmp[1,i] * 35468, 16) - (SarI(tmp[3,i] * 20091, 16) + tmp[3,i]);
    d2 := (SarI(tmp[1,i] * 20091, 16) + tmp[1,i]) + SarI(tmp[3,i] * 35468, 16);
    // Use SarI (arithmetic right shift) because FPC's shr is logical (unsigned)
    a0 := SarI(a + d2 + 4, 3);
    a1 := SarI(b + c2 + 4, 3);
    a2 := SarI(b - c2 + 4, 3);
    a3 := SarI(a - d2 + 4, 3);
    // Add prediction and clip
    (Dst + i * Bps + 0)^ := Clip8b(Integer((Pred + i * Bps + 0)^) + a0);
    (Dst + i * Bps + 1)^ := Clip8b(Integer((Pred + i * Bps + 1)^) + a1);
    (Dst + i * Bps + 2)^ := Clip8b(Integer((Pred + i * Bps + 2)^) + a2);
    (Dst + i * Bps + 3)^ := Clip8b(Integer((Pred + i * Bps + 3)^) + a3);
  end;
end;

// WHT transform: 16 DC coefficients (PInt16 DC) → 16 DCs (PInt16 Out16)
procedure VP8TransformWHT(DC: PInt16; Out16: PInt16);
var
  tmp: array[0..15] of Integer;
  i, a0, a1, a2, a3: Integer;
begin
  for i := 0 to 3 do
  begin
    a0 := DC[0+i] + DC[12+i];
    a1 := DC[4+i] + DC[ 8+i];
    a2 := DC[4+i] - DC[ 8+i];
    a3 := DC[0+i] - DC[12+i];
    tmp[0+i]  := a0 + a1;
    tmp[8+i]  := a0 - a1;
    tmp[4+i]  := a3 + a2;
    tmp[12+i] := a3 - a2;
  end;
  for i := 0 to 3 do
  begin
    a0 := tmp[0 + i*4] + tmp[3 + i*4];
    a1 := tmp[1 + i*4] + tmp[2 + i*4];
    a2 := tmp[1 + i*4] - tmp[2 + i*4];
    a3 := tmp[0 + i*4] - tmp[3 + i*4];
    Out16[0 + i*4] := Int16(SarI(a0 + a1 + 3, 3));
    Out16[1 + i*4] := Int16(SarI(a3 + a2 + 3, 3));
    Out16[2 + i*4] := Int16(SarI(a0 - a1 + 3, 3));
    Out16[3 + i*4] := Int16(SarI(a3 - a2 + 3, 3));
  end;
end;

// ============================================================
// VP8 DSP: INTRA PREDICTION
// ============================================================

// Fill a 16x16 or 8x8 block with a constant value
procedure Fill(Dst: PByte; Val: Byte; W, H, Stride: Integer);
var r: Integer;
begin
  for r := 0 to H-1 do
    FillChar((Dst + r * Stride)^, W, Val);
end;

// ---- 16x16 luma prediction ----
procedure I16x16_DC(Dst: PByte; Top, Left: PByte; Stride: Integer);
var sum, i: Integer;
begin
  sum := 0;
  for i := 0 to 15 do begin Inc(sum, (Left + i)^); Inc(sum, (Top + i)^); end;
  Fill(Dst, Byte((sum + 16) shr 5), 16, 16, Stride);
end;

procedure I16x16_DC_Left(Dst: PByte; Left: PByte; Stride: Integer);
var sum, i: Integer;
begin
  sum := 0;
  for i := 0 to 15 do Inc(sum, (Left + i)^);
  Fill(Dst, Byte((sum + 8) shr 4), 16, 16, Stride);
end;

procedure I16x16_DC_Top(Dst: PByte; Top: PByte; Stride: Integer);
var sum, i: Integer;
begin
  sum := 0;
  for i := 0 to 15 do Inc(sum, (Top + i)^);
  Fill(Dst, Byte((sum + 8) shr 4), 16, 16, Stride);
end;

procedure I16x16_V(Dst: PByte; Top: PByte; Stride: Integer);
var r: Integer;
begin
  for r := 0 to 15 do
    Move(Top^, (Dst + r * Stride)^, 16);
end;

procedure I16x16_H(Dst: PByte; Left: PByte; Stride: Integer);
var r: Integer;
begin
  for r := 0 to 15 do
    FillChar((Dst + r * Stride)^, 16, (Left + r)^);
end;

procedure I16x16_TM(Dst: PByte; Top, Left: PByte; TopLeft: Byte; Stride: Integer);
var r, c, v: Integer;
begin
  for r := 0 to 15 do
    for c := 0 to 15 do
    begin
      v := Integer((Left + r)^) + Integer((Top + c)^) - Integer(TopLeft);
      (Dst + r * Stride + c)^ := Clip8b(v);
    end;
end;

// Predict 16x16 luma into YuvBuf (dst=@YuvBuf[Y_OFF + mbx*16])
// TopCtx: top row Y samples, LeftCtx: left column Y samples
// HasTop, HasLeft: border flags
procedure VP8PredLuma16(Mode: Integer; Dst: PByte; TopCtx, LeftCtx: PByte;
  HasTop, HasLeft: Boolean; Stride: Integer);
var topLeft: Byte;
    tmpLeft: array[0..15] of Byte;
    tmpTop:  array[0..15] of Byte;
    i: Integer;
begin
  if not HasTop  then FillChar(tmpTop,  16, 127) else Move(TopCtx^, tmpTop, 16);
  if not HasLeft then FillChar(tmpLeft, 16, 129) else Move(LeftCtx^, tmpLeft, 16);
  // Top-left corner lives at Dst[-Stride-1] in the YUV buffer.
  // For mby=0 it was initialised to 127; for mby>0,mbx=0 to 129; for mbx>0 the
  // column-rotation copies the last byte of the previous MB's top-row here.
  // Always read the buffer directly — do NOT override with 129 when HasTop=False,
  // because TM_PRED requires the actual value (127 for the first MB row, not 129).
  topLeft := (Dst - Stride - 1)^;
  case Mode of
    DC_PRED:
      if HasTop and HasLeft then I16x16_DC(Dst, @tmpTop[0], @tmpLeft[0], Stride)
      else if HasLeft        then I16x16_DC_Left(Dst, @tmpLeft[0], Stride)
      else if HasTop         then I16x16_DC_Top(Dst, @tmpTop[0], Stride)
      else                        Fill(Dst, 128, 16, 16, Stride);
    V_PRED:  I16x16_V(Dst, @tmpTop[0], Stride);
    H_PRED:  I16x16_H(Dst, @tmpLeft[0], Stride);
    TM_PRED: I16x16_TM(Dst, @tmpTop[0], @tmpLeft[0], topLeft, Stride);
  end;
end;

// ---- 8x8 chroma prediction ----
procedure I8x8_DC(Dst: PByte; Top, Left: PByte; HasTop, HasLeft: Boolean; Stride: Integer);
var sum, i: Integer;
begin
  sum := 0;
  if HasTop  then for i := 0 to 7 do Inc(sum, (Top  + i)^);
  if HasLeft then for i := 0 to 7 do Inc(sum, (Left + i)^);
  if HasTop and HasLeft then Fill(Dst, Byte((sum + 8) shr 4), 8, 8, Stride)
  else if HasTop  then Fill(Dst, Byte((sum + 4) shr 3), 8, 8, Stride)
  else if HasLeft then Fill(Dst, Byte((sum + 4) shr 3), 8, 8, Stride)
  else                 Fill(Dst, 128, 8, 8, Stride);
end;

procedure I8x8_V(Dst: PByte; Top: PByte; Stride: Integer);
var r: Integer;
begin
  for r := 0 to 7 do Move(Top^, (Dst + r * Stride)^, 8);
end;

procedure I8x8_H(Dst: PByte; Left: PByte; Stride: Integer);
var r: Integer;
begin
  for r := 0 to 7 do FillChar((Dst + r * Stride)^, 8, (Left + r)^);
end;

procedure I8x8_TM(Dst: PByte; Top, Left: PByte; TL: Byte; Stride: Integer);
var r, c, v: Integer;
begin
  for r := 0 to 7 do
    for c := 0 to 7 do
    begin
      v := Integer((Left + r)^) + Integer((Top + c)^) - Integer(TL);
      (Dst + r * Stride + c)^ := Clip8b(v);
    end;
end;

procedure VP8PredChroma8(Mode: Integer; Dst: PByte; TopCtx, LeftCtx: PByte;
  HasTop, HasLeft: Boolean; Stride: Integer);
var tmpLeft: array[0..7] of Byte;
    tmpTop:  array[0..7] of Byte;
    tl: Byte;
begin
  if not HasTop  then FillChar(tmpTop,  8, 127) else Move(TopCtx^, tmpTop, 8);
  if not HasLeft then FillChar(tmpLeft, 8, 129) else Move(LeftCtx^, tmpLeft, 8);
  tl := (Dst - Stride - 1)^;
  case Mode of
    DC_PRED: I8x8_DC(Dst, @tmpTop[0], @tmpLeft[0], HasTop, HasLeft, Stride);
    V_PRED:  I8x8_V(Dst, @tmpTop[0], Stride);
    H_PRED:  I8x8_H(Dst, @tmpLeft[0], Stride);
    TM_PRED: I8x8_TM(Dst, @tmpTop[0], @tmpLeft[0], tl, Stride);
  end;
end;

// ---- 4x4 luma intra prediction (for I4x4 macroblocks) ----
// Returns average of 4 bytes at p
function Avg4(a,b,c,d: Integer): Byte; inline;
begin Result := Byte((a+b+c+d+2) shr 2); end;

function Avg3(a,b,c: Integer): Byte; inline;
begin Result := Byte((a+2*b+c+2) shr 2); end;

function Avg2(a,b: Integer): Byte; inline;
begin Result := Byte((a+b+1) shr 1); end;

procedure I4x4_DC(Dst: PByte; Top: PByte; Left: PByte; Stride: Integer);
var s: Integer;
begin
  s := (Top+0)^ + (Top+1)^ + (Top+2)^ + (Top+3)^ +
       (Left+0)^ + (Left+1)^ + (Left+2)^ + (Left+3)^ + 4;
  Fill(Dst, Byte(s shr 3), 4, 4, Stride);
end;

procedure I4x4_TM(Dst: PByte; Top, Left: PByte; TL: Byte; Stride: Integer);
var r, c: Integer;
begin
  for r := 0 to 3 do
    for c := 0 to 3 do
      (Dst + r*Stride + c)^ := Clip8b((Left+r)^ + (Top+c)^ - TL);
end;

procedure I4x4_VE(Dst: PByte; Top: PByte; Stride: Integer);
// Vertical (extrapolate from top)
var r: Integer;
    vals: array[0..3] of Byte;
begin
  vals[0] := Avg3((Top-1)^, (Top+0)^, (Top+1)^);
  vals[1] := Avg3((Top+0)^, (Top+1)^, (Top+2)^);
  vals[2] := Avg3((Top+1)^, (Top+2)^, (Top+3)^);
  vals[3] := Avg3((Top+2)^, (Top+3)^, (Top+4)^);
  for r := 0 to 3 do
    Move(vals[0], (Dst + r*Stride)^, 4);
end;

procedure I4x4_HE(Dst: PByte; Left: PByte; TL: Byte; Stride: Integer);
var c: array[0..3] of Byte;
begin
  c[0] := Avg3(TL,         (Left+0)^, (Left+1)^);
  c[1] := Avg3((Left+0)^,  (Left+1)^, (Left+2)^);
  c[2] := Avg3((Left+1)^,  (Left+2)^, (Left+3)^);
  c[3] := Avg3((Left+2)^,  (Left+3)^, (Left+3)^); // last repeats
  FillChar((Dst + 0*Stride)^, 4, c[0]);
  FillChar((Dst + 1*Stride)^, 4, c[1]);
  FillChar((Dst + 2*Stride)^, 4, c[2]);
  FillChar((Dst + 3*Stride)^, 4, c[3]);
end;

procedure I4x4_RD(Dst: PByte; Top, Left: PByte; TL: Byte; Stride: Integer);
// DST(x,y) = Dst[y*Stride+x]
// X=TL, I=Left[0], J=Left[1], K=Left[2], L=Left[3], A..D=Top[0..3]
var X, I, J, K, L, A, B, C, D: Integer;
begin
  X := TL;          I := (Left+0)^; J := (Left+1)^;
  K := (Left+2)^;   L := (Left+3)^;
  A := (Top+0)^;    B := (Top+1)^;  C := (Top+2)^; D := (Top+3)^;
  (Dst + 3*Stride + 0)^ := Avg3(J, K, L);
  (Dst + 3*Stride + 1)^ := Avg3(I, J, K);
  (Dst + 2*Stride + 0)^ := Avg3(I, J, K);
  (Dst + 3*Stride + 2)^ := Avg3(X, I, J);
  (Dst + 2*Stride + 1)^ := Avg3(X, I, J);
  (Dst + 1*Stride + 0)^ := Avg3(X, I, J);
  (Dst + 3*Stride + 3)^ := Avg3(A, X, I);
  (Dst + 2*Stride + 2)^ := Avg3(A, X, I);
  (Dst + 1*Stride + 1)^ := Avg3(A, X, I);
  (Dst + 0*Stride + 0)^ := Avg3(A, X, I);
  (Dst + 2*Stride + 3)^ := Avg3(B, A, X);
  (Dst + 1*Stride + 2)^ := Avg3(B, A, X);
  (Dst + 0*Stride + 1)^ := Avg3(B, A, X);
  (Dst + 1*Stride + 3)^ := Avg3(C, B, A);
  (Dst + 0*Stride + 2)^ := Avg3(C, B, A);
  (Dst + 0*Stride + 3)^ := Avg3(D, C, B);
end;

procedure I4x4_LD(Dst: PByte; Top: PByte; Stride: Integer);
var t: array[0..7] of Integer;
begin
  t[0]:=(Top+0)^; t[1]:=(Top+1)^; t[2]:=(Top+2)^; t[3]:=(Top+3)^;
  t[4]:=(Top+4)^; t[5]:=(Top+5)^; t[6]:=(Top+6)^; t[7]:=(Top+7)^;
  (Dst+0*Stride+0)^:=Avg3(t[0],t[1],t[2]); (Dst+0*Stride+1)^:=Avg3(t[1],t[2],t[3]);
  (Dst+0*Stride+2)^:=Avg3(t[2],t[3],t[4]); (Dst+0*Stride+3)^:=Avg3(t[3],t[4],t[5]);
  (Dst+1*Stride+0)^:=Avg3(t[1],t[2],t[3]); (Dst+1*Stride+1)^:=Avg3(t[2],t[3],t[4]);
  (Dst+1*Stride+2)^:=Avg3(t[3],t[4],t[5]); (Dst+1*Stride+3)^:=Avg3(t[4],t[5],t[6]);
  (Dst+2*Stride+0)^:=Avg3(t[2],t[3],t[4]); (Dst+2*Stride+1)^:=Avg3(t[3],t[4],t[5]);
  (Dst+2*Stride+2)^:=Avg3(t[4],t[5],t[6]); (Dst+2*Stride+3)^:=Avg3(t[5],t[6],t[7]);
  (Dst+3*Stride+0)^:=Avg3(t[3],t[4],t[5]); (Dst+3*Stride+1)^:=Avg3(t[4],t[5],t[6]);
  (Dst+3*Stride+2)^:=Avg3(t[5],t[6],t[7]); (Dst+3*Stride+3)^:=Avg3(t[6],t[7],t[7]);
end;

procedure I4x4_VR(Dst: PByte; Top, Left: PByte; TL: Byte; Stride: Integer);
// Matches VR4_C: DST(x,y) = (Dst + y*Stride + x)^
// X=TL, I=Left[0], J=Left[1], K=Left[2]; A..D=Top[0..3]
var X, I, J, K, A, B, C, D: Integer;
begin
  X := TL;        I := (Left+0)^; J := (Left+1)^; K := (Left+2)^;
  A := (Top+0)^;  B := (Top+1)^;  C := (Top+2)^;  D := (Top+3)^;
  // DST(0,0)=DST(1,2)=Avg2(X,A)
  (Dst+0*Stride+0)^ := Avg2(X,A);  (Dst+2*Stride+1)^ := Avg2(X,A);
  // DST(1,0)=DST(2,2)=Avg2(A,B)
  (Dst+0*Stride+1)^ := Avg2(A,B);  (Dst+2*Stride+2)^ := Avg2(A,B);
  // DST(2,0)=DST(3,2)=Avg2(B,C)
  (Dst+0*Stride+2)^ := Avg2(B,C);  (Dst+2*Stride+3)^ := Avg2(B,C);
  // DST(3,0)=Avg2(C,D)
  (Dst+0*Stride+3)^ := Avg2(C,D);
  // DST(0,1)=DST(1,3)=Avg3(I,X,A)
  (Dst+1*Stride+0)^ := Avg3(I,X,A);  (Dst+3*Stride+1)^ := Avg3(I,X,A);
  // DST(1,1)=DST(2,3)=Avg3(X,A,B)
  (Dst+1*Stride+1)^ := Avg3(X,A,B);  (Dst+3*Stride+2)^ := Avg3(X,A,B);
  // DST(2,1)=DST(3,3)=Avg3(A,B,C)
  (Dst+1*Stride+2)^ := Avg3(A,B,C);  (Dst+3*Stride+3)^ := Avg3(A,B,C);
  // DST(3,1)=Avg3(B,C,D)
  (Dst+1*Stride+3)^ := Avg3(B,C,D);
  // DST(0,2)=Avg3(J,I,X)
  (Dst+2*Stride+0)^ := Avg3(J,I,X);
  // DST(0,3)=Avg3(K,J,I)
  (Dst+3*Stride+0)^ := Avg3(K,J,I);
end;

procedure I4x4_VL(Dst: PByte; Top: PByte; Stride: Integer);
var t: array[0..7] of Integer;
begin
  t[0]:=(Top+0)^; t[1]:=(Top+1)^; t[2]:=(Top+2)^; t[3]:=(Top+3)^;
  t[4]:=(Top+4)^; t[5]:=(Top+5)^; t[6]:=(Top+6)^; t[7]:=(Top+7)^;
  (Dst+0*Stride+0)^:=Avg2(t[0],t[1]); (Dst+0*Stride+1)^:=Avg2(t[1],t[2]);
  (Dst+0*Stride+2)^:=Avg2(t[2],t[3]); (Dst+0*Stride+3)^:=Avg2(t[3],t[4]);
  (Dst+1*Stride+0)^:=Avg3(t[0],t[1],t[2]); (Dst+1*Stride+1)^:=Avg3(t[1],t[2],t[3]);
  (Dst+1*Stride+2)^:=Avg3(t[2],t[3],t[4]); (Dst+1*Stride+3)^:=Avg3(t[3],t[4],t[5]);
  (Dst+2*Stride+0)^:=Avg2(t[1],t[2]); (Dst+2*Stride+1)^:=Avg2(t[2],t[3]);
  (Dst+2*Stride+2)^:=Avg2(t[3],t[4]); (Dst+2*Stride+3)^:=Avg3(t[4],t[5],t[6]);
  (Dst+3*Stride+0)^:=Avg3(t[1],t[2],t[3]); (Dst+3*Stride+1)^:=Avg3(t[2],t[3],t[4]);
  (Dst+3*Stride+2)^:=Avg3(t[3],t[4],t[5]); (Dst+3*Stride+3)^:=Avg3(t[5],t[6],t[7]);
end;

procedure I4x4_HD(Dst: PByte; Top, Left: PByte; TL: Byte; Stride: Integer);
// Matches HD4_C: DST(x,y) = (Dst + y*Stride + x)^
// X=TL, I=Left[0], J=Left[1], K=Left[2], L=Left[3]; A..C=Top[0..2], D=Top[3]
var X, I, J, K, L, A, B, C, D: Integer;
begin
  X := TL;        I := (Left+0)^; J := (Left+1)^; K := (Left+2)^; L := (Left+3)^;
  A := (Top+0)^;  B := (Top+1)^;  C := (Top+2)^;  D := (Top+3)^;
  // DST(0,0)=DST(2,1)=Avg2(I,X)
  (Dst+0*Stride+0)^ := Avg2(I,X);  (Dst+1*Stride+2)^ := Avg2(I,X);
  // DST(0,1)=DST(2,2)=Avg2(J,I)
  (Dst+1*Stride+0)^ := Avg2(J,I);  (Dst+2*Stride+2)^ := Avg2(J,I);
  // DST(0,2)=DST(2,3)=Avg2(K,J)
  (Dst+2*Stride+0)^ := Avg2(K,J);  (Dst+3*Stride+2)^ := Avg2(K,J);
  // DST(0,3)=Avg2(L,K)
  (Dst+3*Stride+0)^ := Avg2(L,K);
  // DST(3,0)=Avg3(A,B,C)
  (Dst+0*Stride+3)^ := Avg3(A,B,C);
  // DST(2,0)=Avg3(X,A,B)
  (Dst+0*Stride+2)^ := Avg3(X,A,B);
  // DST(1,0)=DST(3,1)=Avg3(I,X,A)
  (Dst+0*Stride+1)^ := Avg3(I,X,A);  (Dst+1*Stride+3)^ := Avg3(I,X,A);
  // DST(1,1)=DST(3,2)=Avg3(J,I,X)
  (Dst+1*Stride+1)^ := Avg3(J,I,X);  (Dst+2*Stride+3)^ := Avg3(J,I,X);
  // DST(1,2)=DST(3,3)=Avg3(K,J,I)
  (Dst+2*Stride+1)^ := Avg3(K,J,I);  (Dst+3*Stride+3)^ := Avg3(K,J,I);
  // DST(1,3)=Avg3(L,K,J)
  (Dst+3*Stride+1)^ := Avg3(L,K,J);
  // Note: D (Top[3]) is not used in HD4
  D := D; // suppress hint
end;

procedure I4x4_HU(Dst: PByte; Left: PByte; Stride: Integer);
var l: array[0..3] of Integer;
begin
  l[0]:=(Left+0)^; l[1]:=(Left+1)^; l[2]:=(Left+2)^; l[3]:=(Left+3)^;
  (Dst+0*Stride+0)^:=Avg2(l[0],l[1]); (Dst+0*Stride+1)^:=Avg3(l[0],l[1],l[2]);
  (Dst+0*Stride+2)^:=Avg2(l[1],l[2]); (Dst+0*Stride+3)^:=Avg3(l[1],l[2],l[3]);
  (Dst+1*Stride+0)^:=Avg2(l[1],l[2]); (Dst+1*Stride+1)^:=Avg3(l[1],l[2],l[3]);
  (Dst+1*Stride+2)^:=Avg2(l[2],l[3]); (Dst+1*Stride+3)^:=Avg3(l[2],l[3],l[3]);
  (Dst+2*Stride+0)^:=Avg2(l[2],l[3]); (Dst+2*Stride+1)^:=Avg3(l[2],l[3],l[3]);
  (Dst+2*Stride+2)^:=l[3];             (Dst+2*Stride+3)^:=l[3];
  (Dst+3*Stride+0)^:=l[3]; (Dst+3*Stride+1)^:=l[3];
  (Dst+3*Stride+2)^:=l[3]; (Dst+3*Stride+3)^:=l[3];
end;

// Predict one 4x4 block in the luma plane
// TopSamples: 8 bytes (4 top + 4 top-right) at Top[0..7]
// LeftSamples: 4 bytes at Left[0..3]
// TopLeft: single byte (top-left corner)
procedure VP8PredLuma4(Mode: Integer; Dst: PByte; Top, Left: PByte;
  TL: Byte; Stride: Integer);
begin
  case Mode of
    B_DC_PRED: I4x4_DC(Dst, Top, Left, Stride);
    B_TM_PRED: I4x4_TM(Dst, Top, Left, TL, Stride);
    B_VE_PRED: I4x4_VE(Dst, Top, Stride);
    B_HE_PRED: I4x4_HE(Dst, Left, TL, Stride);
    B_RD_PRED: I4x4_RD(Dst, Top, Left, TL, Stride);
    B_VR_PRED: I4x4_VR(Dst, Top, Left, TL, Stride);
    B_LD_PRED: I4x4_LD(Dst, Top, Stride);
    B_VL_PRED: I4x4_VL(Dst, Top, Stride);
    B_HD_PRED: I4x4_HD(Dst, Top, Left, TL, Stride);
    B_HU_PRED: I4x4_HU(Dst, Left, Stride);
  end;
end;

// ============================================================
// VP8 MACROBLOCK RECONSTRUCTION
// ============================================================

// Copy 4 bytes: used for left-context updates
procedure Copy4(Dst, Src: PByte); inline;
begin
  PCardinal(Dst)^ := PCardinal(Src)^;
end;

// Reconstruct one macroblock into YuvBuf
// D.MBData must have been populated by VP8ParseResiduals
// YBuf = @YuvBuf[Y_OFF], UBuf = @YuvBuf[U_OFF], VBuf = @YuvBuf[V_OFF]
procedure VP8ReconstructMB(var D: TVP8Decoder; MbX: Integer;
  HasTop, HasLeft: Boolean);
var
  mb:   ^TVP8MBData;
  y, x, n: Integer;
  yBase, uBase, vBase: PByte;
  topY, topU, topV: PByte;
  leftY: array[0..15] of Byte;
  leftU, leftV: array[0..7] of Byte;
  yDst, uDst, vDst: PByte;
  leftCol: array[0..15] of Byte;
begin
  mb := @D.MBData;
  yBase := @D.YuvBuf[Y_OFF];
  uBase := @D.YuvBuf[U_OFF];
  vBase := @D.YuvBuf[V_OFF];

  // Top-row context pointers
  topY := D.YTopBuf + MbX * 16;
  topU := D.UTopBuf + MbX * 8;
  topV := D.VTopBuf + MbX * 8;

  // Left-column context: read from YuvBuf border pixels
  // Left Y: column -1 of Y = yBase - 1, rows 0..15
  // Left U: column -1 of U = uBase - 1, rows 0..7
  if HasLeft then
  begin
    for y := 0 to 15 do leftY[y] := (yBase + y * BPS - 1)^;
    for y := 0 to  7 do leftU[y] := (uBase + y * BPS - 1)^;
    for y := 0 to  7 do leftV[y] := (vBase + y * BPS - 1)^;
  end else
  begin
    FillChar(leftY, 16, 129);
    FillChar(leftU,  8, 129);
    FillChar(leftV,  8, 129);
  end;

  // Luma prediction
  if not mb^.IsI4x4 then
  begin
    // I16x16: predict then apply residuals per 4x4 block
    // WHT DCs were already injected into mb^.Coeffs[n*16+0] by VP8ParseResiduals
    VP8PredLuma16(mb^.IModes[0], yBase, topY, @leftY[0], HasTop, HasLeft, BPS);
    for y := 0 to 3 do
      for x := 0 to 3 do
      begin
        n := y * 4 + x;
        yDst := yBase + kScan[n];
        VP8TransformOne(@mb^.Coeffs[n*16], yDst, yDst, BPS);
      end;
  end else
  begin
    // I4x4: predict each 4x4 sub-block independently, then apply residuals
    for n := 0 to 15 do
    begin
      x := n and 3; y := n shr 2;
      yDst := yBase + kScan[n];
      // Collect left column (4 pixels, strided BPS apart) into contiguous temp
      leftCol[0] := (yDst - 1 + 0*BPS)^;
      leftCol[1] := (yDst - 1 + 1*BPS)^;
      leftCol[2] := (yDst - 1 + 2*BPS)^;
      leftCol[3] := (yDst - 1 + 3*BPS)^;
      VP8PredLuma4(mb^.IModes[n], yDst,
                   yDst - BPS,       // top row (4+4 bytes available)
                   @leftCol[0],      // left column (contiguous 4 bytes)
                   (yDst - BPS - 1)^,
                   BPS);
      // Apply IDCT residuals
      VP8TransformOne(@mb^.Coeffs[n*16], yDst, yDst, BPS);
    end;
  end;

  // Chroma prediction (8x8 U and V)
  VP8PredChroma8(mb^.UVMode, uBase, topU, @leftU[0], HasTop, HasLeft, BPS);
  VP8PredChroma8(mb^.UVMode, vBase, topV, @leftV[0], HasTop, HasLeft, BPS);
  // Apply chroma IDCT (4 blocks each for U and V)
  for n := 0 to 3 do
  begin
    x := n and 1; y := n shr 1;
    uDst := uBase + (x*4) + (y*4*BPS);
    vDst := vBase + (x*4) + (y*4*BPS);
    VP8TransformOne(@mb^.Coeffs[(16+n)*16], uDst, uDst, BPS);
    VP8TransformOne(@mb^.Coeffs[(20+n)*16], vDst, vDst, BPS);
  end;

  // Update top-row context
  Move((yBase + 15*BPS)^, topY^, 16);
  Move((uBase +  7*BPS)^, topU^,  8);
  Move((vBase +  7*BPS)^, topV^,  8);
end;

// ============================================================
// YUV -> RGB OUTPUT CONVERSION
// ============================================================

// Output one row of pixels from the YUV buffer into the output buffer.
// OutputRow: destination (pre-positioned)
// Y, U, V: source row pointers (Y has 'width' pixels, U/V have width/2)
// Width: number of Y pixels
procedure EmitRGBRow(Y, U, V: PByte; Width: Integer;
  Dst: PByte; Mode: TCSMode; Bpp: Integer);
var x: Integer;
    yv, uv, vv: Integer;
    r, g, b: Byte;
    p: PByte;
begin
  for x := 0 to Width-1 do
  begin
    yv := Y[x];
    uv := U[x shr 1];
    vv := V[x shr 1];
    r := YuvToR(yv, vv);
    g := YuvToG(yv, uv, vv);
    b := YuvToB(yv, uv);
    p := Dst + x * Bpp;
    case Mode of
      csmRGBA: begin p[0]:=r; p[1]:=g; p[2]:=b; p[3]:=255; end;
      csmARGB: begin p[0]:=255; p[1]:=r; p[2]:=g; p[3]:=b; end;
      csmBGRA: begin p[0]:=b; p[1]:=g; p[2]:=r; p[3]:=255; end;
      csmRGB:  begin p[0]:=r; p[1]:=g; p[2]:=b; end;
      csmBGR:  begin p[0]:=b; p[1]:=g; p[2]:=r; end;
    end;
  end;
end;

// ============================================================
// VP8 FRAME DECODE
// ============================================================

function VP8DecodeFrame(var D: TVP8Decoder): Boolean;
var
  mby, mbx: Integer;
  hasTop, hasLeft: Boolean;
  partIdx: Integer;
  mb: ^TVP8MBData;
  br: ^TVP8Rd;
  info: PVP8MB;
  yRow, uRow, vRow: PByte;
  outRow: PByte;
  y, x, ix, iy: Integer;
  topCtx: PByte;    // pointer into D.IntraT for current macroblock's 4 columns
  ymode: Integer;
  leftMode: Integer;  // running left context for I4x4 mode parsing
  mbPxW: Integer;   // pixel width of current macroblock (16 or partial last)
  yBase, uBase, vBase: PByte;
  j: Integer;
begin
  Result := False;

  yBase := @D.YuvBuf[Y_OFF];
  uBase := @D.YuvBuf[U_OFF];
  vBase := @D.YuvBuf[V_OFF];

  for mby := 0 to D.MbH-1 do
  begin
    hasTop := (mby > 0);

    // --- Reset left-column context for this row (mirrors VP8InitScanline) ---
    // Left col-(-1) for Y rows 0..15 and U/V rows 0..7
    for j := 0 to 15 do (yBase + j * BPS - 1)^ := 129;
    for j := 0 to  7 do begin (uBase + j * BPS - 1)^ := 129; (vBase + j * BPS - 1)^ := 129; end;

    // Top-left corner and top row initialisation
    if mby = 0 then
    begin
      // First row: no top context → fill top row + top-left with 127
      FillChar((yBase - BPS - 1)^, 16 + 4 + 1, 127);
      FillChar((uBase - BPS - 1)^, 8 + 1, 127);
      FillChar((vBase - BPS - 1)^, 8 + 1, 127);
    end else
    begin
      // Not first row: top-left corner = 129 (border value)
      (yBase - BPS - 1)^ := 129;
      (uBase - BPS - 1)^ := 129;
      (vBase - BPS - 1)^ := 129;
    end;

    // VP8InitScanline: reset left NZ and left intra context
    D.MBInfo^.NZ   := 0;
    D.MBInfo^.NZDC := 0;
    FillChar(D.IntraL, SizeOf(D.IntraL), B_DC_PRED);

    // Token partition for this row (all MBs in a row use the same partition)
    partIdx := mby mod D.NumParts;

    for mbx := 0 to D.MbW-1 do
    begin
      hasLeft := (mbx > 0);

      // --- Rotate right column → left column (left context for this MB) ---
      // Mirrors C's Copy32b(y_dst[j*BPS-4], y_dst[j*BPS+12]) for j=-1..15
      if mbx > 0 then
      begin
        for j := -1 to 15 do (yBase + j * BPS - 1)^ := (yBase + j * BPS + 15)^;
        for j := -1 to  7 do
        begin
          (uBase + j * BPS - 1)^ := (uBase + j * BPS + 7)^;
          (vBase + j * BPS - 1)^ := (vBase + j * BPS + 7)^;
        end;
      end;

      // --- Copy top-row samples into the buffer (needed by I4x4 prediction) ---
      // Mirrors C's memcpy(y_dst-BPS, top_yuv[mb_x].y, 16)
      if hasTop then
      begin
        Move((D.YTopBuf + mbx * 16)^, (yBase - BPS)^, 16);
        Move((D.UTopBuf + mbx *  8)^, (uBase - BPS)^,  8);
        Move((D.VTopBuf + mbx *  8)^, (vBase - BPS)^,  8);
        // Top-right 4 pixels (extend top row beyond the 16-pixel MB width)
        if mbx < D.MbW - 1 then
          Move((D.YTopBuf + (mbx + 1) * 16)^, (yBase - BPS + 16)^, 4)
        else
          FillChar((yBase - BPS + 16)^, 4, (D.YTopBuf + mbx * 16 + 15)^);
      end;
      // Replicate top-right to rows 3/7/11 in the buffer — always, for I4x4
      // (C: top_right[k*BPS] = top_right[0] where top_right is uint32_t*,
      //  stride = BPS * sizeof(uint32_t) = 128 bytes each step)
      PCardinal(yBase + 3  * BPS + 16)^ := PCardinal(yBase - BPS + 16)^;
      PCardinal(yBase + 7  * BPS + 16)^ := PCardinal(yBase - BPS + 16)^;
      PCardinal(yBase + 11 * BPS + 16)^ := PCardinal(yBase - BPS + 16)^;

      mb  := @D.MBData;
      info := PVP8MB(NativeUInt(D.MBInfo) + (mbx+1)*SizeOf(TVP8MB));
      topCtx := D.IntraT + mbx * 4;

      // --- Parse intra modes from partition 0 ---
      br := @D.BR;

      // Segment ID — balanced binary tree (VP8 spec §9.3):
      //   bit0=0 → {0,1} via prob[1];  bit0=1 → {2,3} via prob[2]
      // Always consumes exactly 2 bits when update_map is set.
      if D.SegHdr.UseSegment and D.SegHdr.UpdateMap then
      begin
        if VP8RdGetBit(br^, D.SegHdr.SegProbs[0]) = 0 then
          mb^.Segment := VP8RdGetBit(br^, D.SegHdr.SegProbs[1])
        else
          mb^.Segment := 2 + VP8RdGetBit(br^, D.SegHdr.SegProbs[2]);
      end else
        mb^.Segment := 0;

      // Skip flag (read from partition 0 when use_skip_proba is set)
      if D.UseSkipProba then
        mb^.Skip := VP8RdGetBit(br^, D.SkipP) <> 0
      else
        mb^.Skip := False;

      // Intra mode
      mb^.IsI4x4 := VP8RdGetBit(br^, 145) = 0;
      if not mb^.IsI4x4 then
      begin
        ymode := ParseIntra16Mode(br^);
        // Fill all 16 sub-modes and update top/left context
        for ix := 0 to 15 do mb^.IModes[ix] := ymode;
        // Update IntraT (4 columns) and IntraL (4 rows)
        for ix := 0 to 3 do topCtx[ix] := ymode;
        for iy := 0 to 3 do D.IntraL[iy] := ymode;
      end else
      begin
        // I4x4: read 16 modes with proper top/left context
        // leftMode is the running left-neighbour mode, updated per-pixel (like
        // C's `ymode` variable in ParseIntraMode).
        for iy := 0 to 3 do
        begin
          leftMode := D.IntraL[iy];
          for ix := 0 to 3 do
          begin
            y := ParseIntra4x4Mode(br^,
              kBModesProba[topCtx[ix], leftMode]);
            mb^.IModes[iy*4 + ix] := y;
            topCtx[ix] := y;
            leftMode := y;
          end;
          D.IntraL[iy] := leftMode;  // = last decoded mode in this row
        end;
      end;
      mb^.UVMode := ParseUVMode(br^);

      // --- Residuals from AC partition ---
      if not mb^.Skip then
      begin
        VP8ParseResiduals(D, mbx, D.Parts[partIdx], partIdx);
      end else
      begin
        FillChar(mb^.Coeffs[0], SizeOf(mb^.Coeffs), 0);
        mb^.NonZeroY  := 0;
        mb^.NonZeroUV := 0;
        // clear NZ context
        info^.NZ := 0; info^.NZDC := 0;
        D.MBInfo^.NZ := 0;
      end;

      // --- Reconstruct YUV ---
      VP8ReconstructMB(D, mbx, hasTop, hasLeft);

      // --- Emit this macroblock's strip to the output ---
      // YuvBuf holds only the current 16x16 MB; emit only its 16-pixel-wide columns
      outRow := D.OutBuf + NativeUInt(mby) * 16 * NativeUInt(D.OutStride)
                         + NativeUInt(mbx) * 16 * NativeUInt(D.OutBpp);
      begin
        mbPxW := 16;
        if (mbx + 1) * 16 > D.PicWidth then mbPxW := D.PicWidth - mbx * 16;
        for y := 0 to 15 do
        begin
          if mby * 16 + y >= D.PicHeight then Break;
          yRow := @D.YuvBuf[Y_OFF + y * BPS];
          uRow := @D.YuvBuf[U_OFF + (y shr 1) * BPS];
          vRow := @D.YuvBuf[V_OFF + (y shr 1) * BPS];
          EmitRGBRow(yRow, uRow, vRow, mbPxW,
                     outRow + NativeUInt(y) * NativeUInt(D.OutStride),
                     D.OutputMode, D.OutBpp);
        end;
      end;
    end;
  end;
  Result := True;
end;

// ============================================================
// VP8 FRAME HEADER PARSING
// ============================================================

function VP8ParseHeaders(var D: TVP8Decoder; Data: PByte; Size: NativeUInt): Boolean;
var
  tmp: Cardinal;
  partLen: Cardinal;
  dataBR: TVP8Rd;
  w, h: Integer;
  partData: PByte;
  szPtr:    PByte;
  partSize: NativeUInt;
  i: Integer;
begin
  Result := False;
  if Size < 10 then Exit;

  // 3-byte frame header
  tmp := PByte(Data)[0] or (Cardinal(PByte(Data)[1]) shl 8) or
         (Cardinal(PByte(Data)[2]) shl 16);
  D.KeyFrame := (tmp and 1) = 0;
  D.Profile  := (tmp shr 1) and 7;
  // show_frame = (tmp shr 4) and 1;
  partLen    := (tmp shr 5) and $7FFFF;

  if not D.KeyFrame then Exit;  // we only support key frames

  // 3-byte start code
  if (Data[3] <> $9D) or (Data[4] <> $01) or (Data[5] <> $2A) then Exit;

  // Width/Height
  w := (Data[6] or (Cardinal(Data[7]) shl 8)) and $3FFF;
  h := (Data[8] or (Cardinal(Data[9]) shl 8)) and $3FFF;
  D.PicWidth  := w;
  D.PicHeight := h;
  D.MbW       := (w + 15) shr 4;
  D.MbH       := (h + 15) shr 4;

  D.PartLen0 := partLen;

  // Partition 0: starts at Data+10 (after 3-byte frame tag + 7-byte picture header)
  // Length = partLen (= first_part_size from the frame tag, excludes picture header)
  VP8RdInit(D.BR, Data + 10, partLen);

  // Parse header fields from partition 0
  if VP8RdGet(D.BR) <> 0 then Exit; // color_space must be 0
  VP8RdGet(D.BR); // clamp_type (ignored)

  VP8ParseSegmentHeader(D.BR, D.SegHdr);
  VP8ParseFilterHeader(D.BR, D);
  // Number of token partitions: 2^n (n = 2-bit value)
  D.NumParts := 1 shl Integer(VP8RdGetValue(D.BR, 2));
  VP8ParseQuant(D.BR, D);
  VP8RdGet(D.BR); // update_proba bit — read and ignore (not an error if 1)
  VP8ParseProba(D.BR, D);  // also reads use_skip_proba/skip_p at the end

  // Token partition data starts immediately after partition 0.
  // Layout: [(NumParts-1) × 3-byte sizes][part0 data][part1 data]...
  // partData → size table entries; szPtr → pointer advancing through sizes
  partData := Data + 10 + partLen;           // start of token area (= size table)
  szPtr    := partData;                       // walks through 3-byte size entries
  partData := partData + NativeUInt(D.NumParts - 1) * 3;  // start of actual data
  for i := 0 to D.NumParts - 2 do
  begin
    partSize := szPtr[0] or (Cardinal(szPtr[1]) shl 8) or
                (Cardinal(szPtr[2]) shl 16);
    Inc(szPtr, 3);
    VP8RdInit(D.Parts[i], partData, partSize);
    Inc(partData, partSize);
  end;
  // Last partition: rest of the VP8 chunk
  if NativeUInt(partData) < NativeUInt(Data + Size) then
    partSize := NativeUInt(Data + Size) - NativeUInt(partData)
  else
    partSize := 0;
  VP8RdInit(D.Parts[D.NumParts-1], partData, partSize);

  Result := True;
end;

// ============================================================
// VP8L (LOSSLESS) DECODER
// ============================================================

// VP8L uses a different bitstream format and Huffman coding.
// This is a basic implementation covering the common case.

type
  TVP8LHuffGroup = record
    Tables: array[0..4] of array[0..255] of THuffmanCode;
  end;

// Read the code lengths for a Huffman table using the meta-Huffman codes
procedure ReadHuffCodeLengths(var BR: TVP8LBitReader;
  CodeLengthHuff: PHuffmanCode;
  NumSymbols: Integer;
  out Lengths: array of Integer);
var
  i, sym, code, reps: Integer;
  prev: Integer;
begin
  i := 0; prev := 8;
  while i < NumSymbols do
  begin
    sym := HuffReadSymbol(BR, CodeLengthHuff, HUFF_LUT_BITS);
    if sym < 0 then begin Lengths[i] := 0; Inc(i); Continue; end;
    if sym < 16 then
    begin
      Lengths[i] := sym;
      if sym <> 0 then prev := sym;
      Inc(i);
    end else if sym = 16 then
    begin
      reps := 3 + Integer(VP8LReadBits(BR, 2));
      for code := 0 to reps-1 do
        if i < NumSymbols then begin Lengths[i] := prev; Inc(i); end;
    end else if sym = 17 then
    begin
      reps := 3 + Integer(VP8LReadBits(BR, 3));
      for code := 0 to reps-1 do
        if i < NumSymbols then begin Lengths[i] := 0; Inc(i); end;
    end else  // sym = 18
    begin
      reps := 11 + Integer(VP8LReadBits(BR, 7));
      for code := 0 to reps-1 do
        if i < NumSymbols then begin Lengths[i] := 0; Inc(i); end;
    end;
  end;
end;

function VP8LDecode(Data: PByte; Size: NativeUInt;
  out PixBuf: PByte; out Width, Height: Integer): Boolean;
var
  BR:        TVP8LBitReader;
  w, h:      Integer;
  alphUsed:  Boolean;
  version:   Integer;
  numPixels: Integer;
  i, x, y:   Integer;
  // Transform flags
  hasPredictor:   Boolean;
  hasColorXform:  Boolean;
  hasSubGreen:    Boolean;
  hasColorIndex:  Boolean;
  ciSize:         Integer;
  // Huffman tables
  hg:             TVP8LHuffGroup;
  clLengths:      array[0..18] of Integer;
  clTable:        array[0..255] of THuffmanCode;
  codeLengths:    array[0..4095] of Integer;
  numCodes:       Integer;
  // Decode
  pixel:          Cardinal;
  green, red, blue, alpha: Byte;
  sym:            Integer;
  dist, length:   Integer;
  backX, backY:   Integer;
  pSrc, pDst:     PByte;
  pixelIdx:       Integer;
  outBuf:         PByte;
begin
  Result := False;
  PixBuf := nil;
  Width  := 0;
  Height := 0;

  if Size < 5 then Exit;
  // Signature
  if Data[0] <> $2F then Exit;
  VP8LInitBitReader(BR, Data + 1, Size - 1);

  w := Integer(VP8LReadBits(BR, 14)) + 1;
  h := Integer(VP8LReadBits(BR, 14)) + 1;
  alphUsed := VP8LReadBits(BR, 1) <> 0;
  version  := Integer(VP8LReadBits(BR, 3));
  if version <> 0 then Exit;

  Width  := w;
  Height := h;

  // Skip transforms for now (just mark all absent)
  hasPredictor  := False;
  hasColorXform := False;
  hasSubGreen   := False;
  hasColorIndex := False;

  // Check for transforms
  while VP8LReadBits(BR, 1) <> 0 do
  begin
    case VP8LReadBits(BR, 2) of
      0: hasPredictor  := True;
      1: hasColorXform := True;
      2: hasSubGreen   := True;
      3:
      begin
        hasColorIndex := True;
        ciSize := Integer(VP8LReadBits(BR, 8)) + 1;
      end;
    end;
    // Skip transform data — just note presence for now
    // (A full implementation would decode each transform's metadata here)
    // For now, if any transform is present, bail with unimplemented
    if hasPredictor or hasColorXform then Exit;  // TODO: implement
  end;

  // Read meta-Huffman header
  // huffman_bits = VP8LReadBits(BR, 3) + 2 (number of huffman groups bits)
  // For simple case: 0 = single group
  if VP8LReadBits(BR, 1) <> 0 then Exit;  // meta-Huffman not supported yet

  // Read 5 Huffman tables (green+length, red, blue, alpha, dist)
  for i := 0 to 4 do
  begin
    // Simple code: single value?
    if VP8LReadBits(BR, 1) <> 0 then
    begin
      // Simple code table: 1 or 2 symbols
      numCodes := Integer(VP8LReadBits(BR, 1)) + 1;
      FillChar(codeLengths[0], kAlphabetSize[i] * SizeOf(Integer), 0);
      if numCodes = 1 then
      begin
        codeLengths[VP8LReadBits(BR, 8)] := 1;
      end else
      begin
        codeLengths[VP8LReadBits(BR, 8)] := 1;
        codeLengths[VP8LReadBits(BR, 8)] := 1;
      end;
    end else
    begin
      // Normal Huffman: first read code-length Huffman (19 codes)
      FillChar(clLengths, SizeOf(clLengths), 0);
      numCodes := Integer(VP8LReadBits(BR, 4)) + 4;
      for sym := 0 to numCodes-1 do
        clLengths[kCodeLengthCodeOrder[sym]] := Integer(VP8LReadBits(BR, 3));
      VP8LBuildHuffmanTable(clLengths, 19, @clTable[0], HUFF_LUT_BITS);
      // Read symbol lengths using code-length Huffman
      FillChar(codeLengths[0], kAlphabetSize[i] * SizeOf(Integer), 0);
      ReadHuffCodeLengths(BR, @clTable[0], kAlphabetSize[i], codeLengths);
    end;
    VP8LBuildHuffmanTable(codeLengths, kAlphabetSize[i], @hg.Tables[i][0], HUFF_LUT_BITS);
  end;

  // Allocate output: RGBA
  numPixels := w * h;
  outBuf    := AllocMem(numPixels * 4);
  PixBuf    := outBuf;

  // Decode pixels
  pixelIdx := 0;
  x := 0; y := 0;
  while pixelIdx < numPixels do
  begin
    // Read green channel (also encodes literal/copy/palette commands)
    sym := HuffReadSymbol(BR, @hg.Tables[0][0], HUFF_LUT_BITS);
    if sym < 0 then Break;

    if sym < 256 then
    begin
      // Literal pixel: green=sym
      green := sym;
      red   := Byte(HuffReadSymbol(BR, @hg.Tables[1][0], HUFF_LUT_BITS));
      blue  := Byte(HuffReadSymbol(BR, @hg.Tables[2][0], HUFF_LUT_BITS));
      alpha := Byte(HuffReadSymbol(BR, @hg.Tables[3][0], HUFF_LUT_BITS));
      if hasSubGreen then
      begin
        red  := Byte(Integer(red)  + Integer(green));
        blue := Byte(Integer(blue) + Integer(green));
      end;
      outBuf[pixelIdx*4+0] := red;
      outBuf[pixelIdx*4+1] := green;
      outBuf[pixelIdx*4+2] := blue;
      outBuf[pixelIdx*4+3] := alpha;
      Inc(pixelIdx);
      Inc(x); if x >= w then begin x := 0; Inc(y); end;
    end else if sym < 256 + 24 then
    begin
      // Back-reference: copy from earlier decoded data
      // length code = sym - 256
      sym := sym - 256;
      // Length extras
      if sym < 4 then
        length := sym + 1
      else
      begin
        length := (1 shl ((sym-2) shr 1)) + 1;
        length := length + Integer(VP8LReadBits(BR, (sym-2) shr 1));
      end;
      // Distance code
      dist := Integer(HuffReadSymbol(BR, @hg.Tables[4][0], HUFF_LUT_BITS));
      if dist < 4 then
        dist := dist + 1
      else
      begin
        dist := (1 shl ((dist-2) shr 1)) + 1;
        dist := dist + Integer(VP8LReadBits(BR, (dist-2) shr 1));
      end;
      // Convert distance to (dx, dy)
      if dist <= 120 then
      begin
        backX := (kCodeToPlane[dist-1] shr 4) and $F;
        backY := kCodeToPlane[dist-1] and $F;
        if (kCodeToPlane[dist-1] and $80) <> 0 then backX := -backX;
      end else
      begin
        backX := -(dist - 1) mod w;
        backY := (dist - 1) div w + 1;
      end;
      // Copy pixels
      for i := 0 to length-1 do
      begin
        if pixelIdx >= numPixels then Break;
        backX := x - backX; backY := y - backY;
        if backX < 0 then begin Dec(backY); Inc(backX, w); end;
        if backX >= w then begin Inc(backY); Dec(backX, w); end;
        if (backX >= 0) and (backY >= 0) and (backX < w) and (backY < h) then
        begin
          pSrc := outBuf + (backY * w + backX) * 4;
          pDst := outBuf + pixelIdx * 4;
          pDst[0] := pSrc[0]; pDst[1] := pSrc[1];
          pDst[2] := pSrc[2]; pDst[3] := pSrc[3];
        end;
        Inc(pixelIdx);
        Inc(x); if x >= w then begin x := 0; Inc(y); end;
      end;
    end else
    begin
      // Color cache (sym >= 280): not supported
      Inc(pixelIdx);
      Inc(x); if x >= w then begin x := 0; Inc(y); end;
    end;
  end;
  Result := True;
end;

// ============================================================
// RIFF CONTAINER PARSER
// ============================================================

function ReadLE32(p: PByte): Cardinal; inline;
begin
  Result := p[0] or (Cardinal(p[1]) shl 8) or
            (Cardinal(p[2]) shl 16) or (Cardinal(p[3]) shl 24);
end;

type
  TWebPChunk = record
    FourCC: Cardinal;
    Size:   Cardinal;
    Data:   PByte;
  end;

function FindChunk(const RIFF: PByte; RiffSize: NativeUInt;
  const Tag: AnsiString; out Chunk: TWebPChunk): Boolean;
var
  p:    PByte;
  left: NativeUInt;
  cc, sz: Cardinal;
  tagCC: Cardinal;
begin
  Result := False;
  tagCC := Ord(Tag[1]) or (Cardinal(Ord(Tag[2])) shl 8) or
           (Cardinal(Ord(Tag[3])) shl 16) or (Cardinal(Ord(Tag[4])) shl 24);
  p    := RIFF;
  left := RiffSize;
  while left >= 8 do
  begin
    cc := ReadLE32(p);
    sz := ReadLE32(p + 4);
    if cc = tagCC then
    begin
      Chunk.FourCC := cc;
      Chunk.Size   := sz;
      Chunk.Data   := p + 8;
      Result := True;
      Exit;
    end;
    // align to 2 bytes
    sz := (sz + 1) and (not 1);
    Inc(p, 8 + sz);
    if 8 + sz > left then Break;
    Dec(left, 8 + sz);
  end;
end;

// Parse RIFF header and locate the VP8/VP8L/VP8X chunk.
// Returns: 1 = VP8 lossy, 2 = VP8L lossless, 0 = error
function ParseRIFF(Data: PByte; Size: NativeUInt;
  out ChunkData: PByte; out ChunkSize: NativeUInt;
  out IsLossless: Boolean;
  out HasAlpha: Boolean): Integer;
var
  riffTag, webpTag, fmtTag: Cardinal;
  riffSize: Cardinal;
  inner: PByte;
  innerSize: NativeUInt;
  chunk: TWebPChunk;
  vp8x_flags: Cardinal;
  alphaChunk: TWebPChunk;
begin
  Result    := 0;
  IsLossless := False;
  HasAlpha   := False;
  ChunkData  := nil;
  ChunkSize  := 0;
  if Size < 12 then Exit;

  riffTag := ReadLE32(Data);
  riffSize := ReadLE32(Data + 4);
  webpTag := ReadLE32(Data + 8);

  // 'RIFF'
  if riffTag <> $46464952 then Exit;
  // 'WEBP'
  if webpTag <> $50424557 then Exit;

  inner     := Data + 12;
  innerSize := Size - 12;

  // Try VP8X (extended format)
  if FindChunk(inner, innerSize, 'VP8X', chunk) then
  begin
    if chunk.Size >= 10 then
    begin
      vp8x_flags := ReadLE32(chunk.Data);
      HasAlpha    := (vp8x_flags and 16) <> 0;
    end;
    // Now find actual image chunk
    if FindChunk(inner, innerSize, 'VP8L', chunk) then
    begin
      ChunkData  := chunk.Data;
      ChunkSize  := chunk.Size;
      IsLossless := True;
      Result     := 2;
      Exit;
    end;
    if FindChunk(inner, innerSize, 'VP8 ', chunk) then
    begin
      ChunkData  := chunk.Data;
      ChunkSize  := chunk.Size;
      IsLossless := False;
      Result     := 1;
      Exit;
    end;
    Exit;
  end;

  // Try VP8L directly
  if FindChunk(inner, innerSize, 'VP8L', chunk) then
  begin
    ChunkData  := chunk.Data;
    ChunkSize  := chunk.Size;
    IsLossless := True;
    Result     := 2;
    Exit;
  end;

  // Try VP8 (lossy) directly
  if FindChunk(inner, innerSize, 'VP8 ', chunk) then
  begin
    ChunkData  := chunk.Data;
    ChunkSize  := chunk.Size;
    IsLossless := False;
    Result     := 1;
    Exit;
  end;
end;

// ============================================================
// VP8 LOSSY DECODE (FULL DRIVER)
// ============================================================

function VP8Decode(Data: PByte; DataSize: NativeUInt;
  Mode: TCSMode; out Width, Height: Integer): PByte;
var
  D:          TVP8Decoder;
  outSize:    NativeUInt;
  topBufSize: NativeUInt;
  topBuf:     PByte;
  mbInfoSz:   NativeUInt;
  i:          Integer;
begin
  Result := nil;
  Width  := 0;
  Height := 0;

  FillChar(D, SizeOf(D), 0);
  D.OutputMode := Mode;
  case Mode of
    csmRGB, csmBGR:     D.OutBpp := 3;
    else                D.OutBpp := 4;
  end;
  D.SegHdr.UseSegment := False;
  D.SegHdr.AbsoluteDelta := True;

  if not VP8ParseHeaders(D, Data, DataSize) then Exit;
  Width  := D.PicWidth;
  Height := D.PicHeight;

  // Allocate output buffer
  D.OutStride := D.PicWidth * D.OutBpp;
  outSize  := NativeUInt(D.PicHeight) * NativeUInt(D.OutStride);
  D.OutBuf := AllocMem(outSize);

  // Allocate top-row context buffers
  topBufSize := D.MbW * 32;  // 16Y + 8U + 8V per MB column
  topBuf     := AllocMem(topBufSize);
  FillChar(topBuf^, topBufSize, 127);
  D.YTopBuf  := topBuf;
  D.UTopBuf  := topBuf + D.MbW * 16;
  D.VTopBuf  := topBuf + D.MbW * 24;

  // Allocate MB info array (MbW+1 entries)
  mbInfoSz := (D.MbW + 1) * SizeOf(TVP8MB);
  D.MBInfo  := PVP8MB(AllocMem(mbInfoSz));
  FillChar(D.MBInfo^, mbInfoSz, 0);

  // Allocate I4x4 top-context array and initialize to B_DC_PRED
  D.IntraT := AllocMem(D.MbW * 4 + 4);
  FillChar(D.IntraT^, D.MbW * 4 + 4, B_DC_PRED);

  // Initialize YUV buffer
  FillChar(D.YuvBuf, SizeOf(D.YuvBuf), 128);
  // Left border column (col -1 of Y/U/V, used as left context for first MB column)
  for i := 0 to 15 do D.YuvBuf[Y_OFF + i * BPS - 1] := 129;
  for i := 0 to  7 do D.YuvBuf[U_OFF + i * BPS - 1] := 129;
  for i := 0 to  7 do D.YuvBuf[V_OFF + i * BPS - 1] := 129;

  if VP8DecodeFrame(D) then
    Result := D.OutBuf
  else
  begin
    FreeMem(D.OutBuf);
    D.OutBuf := nil;
  end;

  FreeMem(topBuf);
  FreeMem(D.MBInfo);
  FreeMem(D.IntraT);
end;

// ============================================================
// PUBLIC API
// ============================================================

function WebPGetInfo(Data: PByte; DataSize: NativeUInt;
  out Width, Height: Integer): Boolean;
var
  chunkData: PByte;
  chunkSize: NativeUInt;
  isLossless, hasAlpha: Boolean;
  riffType: Integer;
  BR:  TVP8LBitReader;
  tmp: Cardinal;
  w, h: Integer;
begin
  Result := False;
  Width  := 0;
  Height := 0;
  if DataSize < 12 then Exit;

  riffType := ParseRIFF(Data, DataSize, chunkData, chunkSize, isLossless, hasAlpha);
  if riffType = 0 then Exit;

  if isLossless then
  begin
    // VP8L: signature + 14+14 bits
    if chunkSize < 5 then Exit;
    if chunkData[0] <> $2F then Exit;
    VP8LInitBitReader(BR, chunkData + 1, chunkSize - 1);
    Width  := Integer(VP8LReadBits(BR, 14)) + 1;
    Height := Integer(VP8LReadBits(BR, 14)) + 1;
    Result := True;
  end else
  begin
    // VP8: 3-byte frame header + start code + w/h
    if chunkSize < 10 then Exit;
    tmp := chunkData[0] or (Cardinal(chunkData[1]) shl 8) or
           (Cardinal(chunkData[2]) shl 16);
    if (tmp and 1) <> 0 then Exit; // not a key frame
    if (chunkData[3] <> $9D) or (chunkData[4] <> $01) or (chunkData[5] <> $2A) then Exit;
    Width  := (chunkData[6] or (Cardinal(chunkData[7]) shl 8)) and $3FFF;
    Height := (chunkData[8] or (Cardinal(chunkData[9]) shl 8)) and $3FFF;
    Result := True;
  end;
end;

function InternalDecode(Data: PByte; DataSize: NativeUInt;
  Mode: TCSMode; out Width, Height: Integer): PByte;
var
  chunkData: PByte;
  chunkSize: NativeUInt;
  isLossless, hasAlpha: Boolean;
  riffType: Integer;
  lsBuf: PByte;
  lsW, lsH: Integer;
  outBuf: PByte;
  i: Integer;
begin
  Result := nil;
  Width  := 0;
  Height := 0;

  riffType := ParseRIFF(Data, DataSize, chunkData, chunkSize, isLossless, hasAlpha);
  if riffType = 0 then Exit;

  if isLossless then
  begin
    if not VP8LDecode(chunkData, chunkSize, lsBuf, lsW, lsH) then Exit;
    Width  := lsW;
    Height := lsH;
    // lsBuf is RGBA; convert to requested mode if needed
    if Mode = csmRGBA then
    begin
      Result := lsBuf;
      Exit;
    end;
    // Convert RGBA to target mode
    case Mode of
      csmARGB:
      begin
        outBuf := AllocMem(lsW * lsH * 4);
        for i := 0 to lsW * lsH - 1 do
        begin
          outBuf[i*4+0] := lsBuf[i*4+3]; // A
          outBuf[i*4+1] := lsBuf[i*4+0]; // R
          outBuf[i*4+2] := lsBuf[i*4+1]; // G
          outBuf[i*4+3] := lsBuf[i*4+2]; // B
        end;
        FreeMem(lsBuf);
        Result := outBuf;
      end;
      csmBGRA:
      begin
        outBuf := AllocMem(lsW * lsH * 4);
        for i := 0 to lsW * lsH - 1 do
        begin
          outBuf[i*4+0] := lsBuf[i*4+2]; // B
          outBuf[i*4+1] := lsBuf[i*4+1]; // G
          outBuf[i*4+2] := lsBuf[i*4+0]; // R
          outBuf[i*4+3] := lsBuf[i*4+3]; // A
        end;
        FreeMem(lsBuf);
        Result := outBuf;
      end;
      csmRGB:
      begin
        outBuf := AllocMem(lsW * lsH * 3);
        for i := 0 to lsW * lsH - 1 do
        begin
          outBuf[i*3+0] := lsBuf[i*4+0];
          outBuf[i*3+1] := lsBuf[i*4+1];
          outBuf[i*3+2] := lsBuf[i*4+2];
        end;
        FreeMem(lsBuf);
        Result := outBuf;
      end;
      csmBGR:
      begin
        outBuf := AllocMem(lsW * lsH * 3);
        for i := 0 to lsW * lsH - 1 do
        begin
          outBuf[i*3+0] := lsBuf[i*4+2];
          outBuf[i*3+1] := lsBuf[i*4+1];
          outBuf[i*3+2] := lsBuf[i*4+0];
        end;
        FreeMem(lsBuf);
        Result := outBuf;
      end;
    end;
  end else
  begin
    Result := VP8Decode(chunkData, chunkSize, Mode, Width, Height);
  end;
end;

function WebPDecodeRGBA(Data: PByte; DataSize: NativeUInt;
  out Width, Height: Integer): PByte;
begin
  Result := InternalDecode(Data, DataSize, csmRGBA, Width, Height);
end;

function WebPDecodeARGB(Data: PByte; DataSize: NativeUInt;
  out Width, Height: Integer): PByte;
begin
  Result := InternalDecode(Data, DataSize, csmARGB, Width, Height);
end;

function WebPDecodeBGRA(Data: PByte; DataSize: NativeUInt;
  out Width, Height: Integer): PByte;
begin
  Result := InternalDecode(Data, DataSize, csmBGRA, Width, Height);
end;

function WebPDecodeRGB(Data: PByte; DataSize: NativeUInt;
  out Width, Height: Integer): PByte;
begin
  Result := InternalDecode(Data, DataSize, csmRGB, Width, Height);
end;

function WebPDecodeBGR(Data: PByte; DataSize: NativeUInt;
  out Width, Height: Integer): PByte;
begin
  Result := InternalDecode(Data, DataSize, csmBGR, Width, Height);
end;

end.
