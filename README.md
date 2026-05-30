# Webp for Delphi and Lazarus

Only decoding for now

## Usage

Add WebpImageX to your uses, then:
```
Image1.Picture.LoadFromFile('test.webp');
```

## Saving
```
var web: TWebpImage;
    Bmp: TBitmap;
begin
  Bmp := TBitmap.Create;
  Bmp.LoadFromFile('test.bmp');

  web := TWebpImage.Create;
  web.Assign(Bmp);
  Bmp.Free;

  web.SaveToFile('out.webp');
  web.free;
end;
```
