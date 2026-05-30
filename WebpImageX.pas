unit WebpImageX;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}

////////////////////////////////////////////////////////////////////////////////
//                                                                            //
// Description:	Reader for WEBP images                    //
// Version:	0.3                                                           //
// Date:	28-MAY-2026                                                   //
// License:     MIT                                                           //
// Target:	Win64, Free Pascal, Delphi                                    //
// Copyright:	(c) 2025 Xelitan.com.                                         //
//		All rights reserved.                                          //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////

interface

uses Classes, Graphics, SysUtils, Math, Types, Dialogs, WebpDec {$IFDEF FPC}, FPImage, IntfGraphics{$ENDIF};

  { TWebpImage }
type
  TWebpImage = class(TGraphic)
  private
    FBmp: TBitmap;
    procedure DecodeFromStream(Str: TStream);
  protected
    procedure Draw(ACanvas: TCanvas; const Rect: TRect); override;
  //    function GetEmpty: Boolean; virtual; abstract;
    function GetHeight: Integer; override;
    function GetTransparent: Boolean; override;
    function GetWidth: Integer; override;
    procedure SetHeight(Value: Integer); override;
    procedure SetTransparent(Value: Boolean); override;
    procedure SetWidth(Value: Integer);override;

    procedure DecodeFromStreamWindows(Str: TStream);
    procedure DecodeFromStreamLinux(Str: TStream);
  public
    procedure Assign(Source: TPersistent); override;
    procedure LoadFromStream(Stream: TStream); override;
    procedure SaveToStream(Stream: TStream); override;
    constructor Create; override;
    destructor Destroy; override;
    function ToBitmap: TBitmap;
  end;

implementation

{ TWebpImage }

procedure TWebpImage.DecodeFromStream(Str: TStream);
begin
{$IFDEF MSWINDOWS}
  DecodeFromStreamWindows(Str);
{$ELSE}
  {$IFDEF LINUX}
  DecodeFromStreamLinux(Str);
  {$ELSE}
  raise EInvalidGraphic.Create('WebP decode: unsupported platform');
  {$ENDIF}
{$ENDIF}
end;

procedure TWebpImage.DecodeFromStreamLinux(Str: TStream);
var
  Data    : array of Byte;
  DataSize: NativeUInt;
  Pixels  : PByte;
  W, H    : Integer;
  x, y    : Integer;
  P       : PByte;
  C       : TFPColor;
  IntfImg : TLazIntfImage;
begin
  DataSize := NativeUInt(Str.Size - Str.Position);
  if DataSize = 0 then
    raise EInvalidGraphic.Create('WebP: empty stream');

  SetLength(Data, DataSize);
  Str.ReadBuffer(Data[0], DataSize);

  // WebPDecodeBGRA writes B,G,R,A per pixel.
  Pixels := WebPDecodeBGRA(@Data[0], DataSize, W, H);
  if Pixels = nil then
    raise EInvalidGraphic.Create('WebP decode failed');

  try
    FBmp.PixelFormat := pf32bit;
    FBmp.SetSize(W, H);

    IntfImg := TLazIntfImage.Create(W, H);
    try
      P := Pixels;

      for y := 0 to H - 1 do
        for x := 0 to W - 1 do
        begin
          // BGRA, 8-bit per channel.
          // TFPColor uses 16-bit channels.
          C.Blue  := Word(P[0]) * $101;
          C.Green := Word(P[1]) * $101;
          C.Red   := Word(P[2]) * $101;
          C.Alpha := Word(P[3]) * $101;

          IntfImg.Colors[x, y] := C;

          Inc(P, 4);
        end;

      FBmp.LoadFromIntfImage(IntfImg);
    finally
      IntfImg.Free;
    end;
  finally
    FreeMem(Pixels);
  end;
end;

procedure TWebpImage.DecodeFromStreamWindows(Str: TStream);
var
  Data    : array of Byte;
  DataSize: NativeUInt;
  Pixels  : PByte;
  W, H, y : Integer;
begin
  DataSize := NativeUInt(Str.Size - Str.Position);
  if DataSize = 0 then
    raise EInvalidGraphic.Create('WebP: empty stream');

  SetLength(Data, DataSize);
  Str.ReadBuffer(Data[0], DataSize);

  // WebPDecodeBGRA writes B,G,R,A per pixel — identical to the Windows
  // 32-bit DIB layout used by TBitmap.ScanLine when PixelFormat = pf32bit.
  Pixels := WebPDecodeBGRA(@Data[0], DataSize, W, H);
  if Pixels = nil then
    raise EInvalidGraphic.Create('WebP decode failed');
  try
    FBmp.PixelFormat := pf32bit;
    FBmp.SetSize(W, H);

    for y := 0 to H - 1 do
      Move((Pixels + NativeUInt(y) * NativeUInt(W) * 4)^,
           FBmp.ScanLine[y]^,
           W * 4);
  finally
    FreeMem(Pixels);
  end;
end;

procedure TWebpImage.Draw(ACanvas: TCanvas; const Rect: TRect);
begin
  ACanvas.StretchDraw(Rect, FBmp);
end;

function TWebpImage.GetHeight: Integer;
begin
  Result := FBmp.Height;
end;

function TWebpImage.GetTransparent: Boolean;
begin
  Result := False;
end;

function TWebpImage.GetWidth: Integer;
begin
  Result := FBmp.Width;
end;

procedure TWebpImage.SetHeight(Value: Integer);
begin
  FBmp.Height := Value;
end;

procedure TWebpImage.SetTransparent(Value: Boolean);
begin
  //
end;

procedure TWebpImage.SetWidth(Value: Integer);
begin
  FBmp.Width := Value;
end;

procedure TWebpImage.Assign(Source: TPersistent);
var Src: TGraphic;
begin
  if source is tgraphic then begin
    Src := Source as TGraphic;
    FBmp.SetSize(Src.Width, Src.Height);
    FBmp.Canvas.Draw(0,0, Src);
  end;
end;

procedure TWebpImage.LoadFromStream(Stream: TStream);
begin
  DecodeFromStream(Stream);
end;

procedure TWebpImage.SaveToStream(Stream: TStream);
begin
  //raise exception here
end;

constructor TWebpImage.Create;
begin
  inherited Create;

  FBmp := TBitmap.Create;
  FBmp.PixelFormat := pf32bit;
  FBmp.SetSize(1,1);
end;

destructor TWebpImage.Destroy;
begin
  FBmp.Free;
  inherited Destroy;
end;

function TWebpImage.ToBitmap: TBitmap;
begin
  Result := FBmp;
end;

initialization
  TPicture.RegisterFileFormat('Webp','Webp Image', TWebpImage);

finalization
  TPicture.UnregisterGraphicClass(TWebpImage);

end.
