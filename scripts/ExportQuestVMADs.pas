unit ExportQuestVMADs_ToJSON;

interface
uses xEditAPI, SysUtils, Classes;

implementation

var
  gJson: TStringList;
  gOutPath: string;

  gQuestCount: Integer;
  gScriptCount: Integer;
  gPropCount: Integer;
  gAliasCount: Integer;

  // JSON writer state
  gIndent: Integer;
  gNeedComma: TStringList; // stack of "0"/"1"

  // Source file capture (canonical: from first processed record's owning file)
  gSourceFileSet: Boolean;
  gSourceFileLineIndex: Integer;

function IndentStr: string;
var i: Integer;
begin
  Result := '';
  for i := 1 to gIndent do
    Result := Result + '  ';
end;

procedure AddLine(const s: string);
begin
  gJson.Add(IndentStr + s);
end;

function LastChar(const s: string): string;
begin
  if Length(s) = 0 then Result := ''
  else Result := Copy(s, Length(s), 1);
end;

procedure AppendCommaToLastLineIfPossible;
var idx: Integer; s, lc: string;
begin
  idx := gJson.Count - 1;
  if idx < 0 then Exit;

  s := gJson[idx];
  lc := LastChar(s);

  if (lc <> ',') and (s <> IndentStr + '{') and (s <> IndentStr + '[') then
    gJson[idx] := s + ',';
end;

procedure EnsureCommaIfNeeded;
var top: Integer;
begin
  top := gNeedComma.Count - 1;
  if top < 0 then Exit;
  if gNeedComma[top] = '1' then
    AppendCommaToLastLineIfPossible;
end;

procedure MarkWroteItem;
var top: Integer;
begin
  top := gNeedComma.Count - 1;
  if top < 0 then Exit;
  gNeedComma[top] := '1';
end;

procedure PushContainer;
begin
  gNeedComma.Add('0');
end;

procedure PopContainer;
begin
  if gNeedComma.Count > 0 then
    gNeedComma.Delete(gNeedComma.Count - 1);
end;

function JsonEscape(const s: string): string;
var i: Integer; ch: string;
begin
  Result := '';
  for i := 1 to Length(s) do begin
    ch := Copy(s, i, 1);
    if ch = '"'  then Result := Result + '\"'
    else if ch = '\' then Result := Result + '\\'
    else if ch = #8  then Result := Result + '\b'
    else if ch = #9  then Result := Result + '\t'
    else if ch = #10 then Result := Result + '\n'
    else if ch = #12 then Result := Result + '\f'
    else if ch = #13 then Result := Result + '\r'
    else Result := Result + ch;
  end;
end;

function Quote(const s: string): string;
begin
  Result := '"' + JsonEscape(s) + '"';
end;

function IsDigitChar(const ch: string): Boolean;
begin
  Result :=
    (ch = '0') or (ch = '1') or (ch = '2') or (ch = '3') or (ch = '4') or
    (ch = '5') or (ch = '6') or (ch = '7') or (ch = '8') or (ch = '9');
end;

function LooksLikeBool(const s: string): Boolean;
begin
  Result := SameText(s, 'true') or SameText(s, 'false') or SameText(s, 'yes') or SameText(s, 'no');
end;

function ToJsonBool(const s: string): string;
begin
  if SameText(s, 'true') or SameText(s, 'yes') then Result := 'true'
  else Result := 'false';
end;

function LooksLikeInt(const s: string): Boolean;
var i, startAt: Integer; ch: string;
begin
  Result := False;
  if s = '' then Exit;

  startAt := 1;
  if Copy(s, 1, 1) = '-' then begin
    if Length(s) = 1 then Exit;
    startAt := 2;
  end;

  for i := startAt to Length(s) do begin
    ch := Copy(s, i, 1);
    if not IsDigitChar(ch) then Exit;
  end;

  Result := True;
end;

function LooksLikeFloat(const s: string): Boolean;
var i, dotCount: Integer; ch: string;
begin
  Result := False;
  if s = '' then Exit;

  dotCount := 0;
  for i := 1 to Length(s) do begin
    ch := Copy(s, i, 1);
    if ch = '.' then Inc(dotCount)
    else if (ch <> '-') and (not IsDigitChar(ch)) then Exit;
  end;

  Result := (dotCount = 1);
end;

function SafePath(e: IInterface; const p: string): IInterface;
begin
  if Assigned(e) then Result := ElementByPath(e, p)
  else Result := nil;
end;

function FindFirstDescByExactName(root: IInterface; const wanted: string): IInterface;
var
  i, n: Integer;
  c, r: IInterface;
begin
  Result := nil;
  if not Assigned(root) then Exit;

  if SameText(Name(root), wanted) then begin
    Result := root;
    Exit;
  end;

  n := ElementCount(root);
  for i := 0 to n - 1 do begin
    c := ElementByIndex(root, i);
    if SameText(Name(c), wanted) then begin
      Result := c;
      Exit;
    end;
    r := FindFirstDescByExactName(c, wanted);
    if Assigned(r) then begin
      Result := r;
      Exit;
    end;
  end;
end;

function GetEditValueIfPath(root: IInterface; const p: string): string;
var t: IInterface;
begin
  Result := '';
  t := SafePath(root, p);
  if Assigned(t) then Result := GetEditValue(t);
end;

function GetScriptNameString(script: IInterface): string;
begin
  Result := GetEditValueIfPath(script, 'scriptName');
  if Result = '' then Result := GetElementEditValues(script, 'scriptName');
  if Result = '' then Result := Name(script);
end;

function GetPropNameString(prop: IInterface): string;
begin
  Result := GetEditValueIfPath(prop, 'propertyName');
  if Result = '' then Result := GetElementEditValues(prop, 'propertyName');
  if Result = '' then Result := Name(prop);
end;

function GetPropTypeString(prop: IInterface): string;
begin
  Result := GetEditValueIfPath(prop, 'Type');
  if Result = '' then Result := GetElementEditValues(prop, 'Type');
  if Result = '' then Result := Name(SafePath(prop, 'Type'));
end;

function GetBestValueString(anyNode: IInterface): string;
var
  vNode, fidNode: IInterface;
begin
  Result := '';

  // 1) Exact "Value" (many primitives)
  vNode := SafePath(anyNode, 'Value');
  if Assigned(vNode) then begin
    // If there's any FormID descendant under Value union/object, use that
    fidNode := FindFirstDescByExactName(vNode, 'FormID');
    if Assigned(fidNode) then begin
      Result := GetEditValue(fidNode);
      Exit;
    end;
    Result := GetEditValue(vNode);
    Exit;
  end;

  // 2) Sometimes the element itself *is* the value
  fidNode := FindFirstDescByExactName(anyNode, 'FormID');
  if Assigned(fidNode) then begin
    Result := GetEditValue(fidNode);
    Exit;
  end;

  Result := GetEditValue(anyNode);
end;

function IsArrayProp(prop: IInterface; const propType: string): Boolean;
begin
  Result :=
    Assigned(SafePath(prop, 'Value\Array')) or
    Assigned(SafePath(prop, 'Value\Array of Struct')) or
    Assigned(SafePath(prop, 'Array')) or
    (Pos('Array', propType) > 0);
end;

function IsStructProp(prop: IInterface; const propType: string): Boolean;
begin
  Result :=
    Assigned(SafePath(prop, 'Value\Struct')) or
    Assigned(SafePath(prop, 'Struct')) or
    (Pos('Struct', propType) > 0);
end;

procedure JsonBeginObject;
begin
  EnsureCommaIfNeeded;
  AddLine('{');
  MarkWroteItem;
  Inc(gIndent);
  PushContainer;
end;

procedure JsonEndObject;
begin
  PopContainer;
  Dec(gIndent);
  AddLine('}');
end;

procedure JsonKeyRaw(const key, rawValue: string);
begin
  EnsureCommaIfNeeded;
  AddLine(Quote(key) + ': ' + rawValue);
  MarkWroteItem;
end;

procedure JsonKeyString(const key, val: string);
begin
  JsonKeyRaw(key, Quote(val));
end;

procedure JsonKeyInt(const key: string; i: Integer);
begin
  JsonKeyRaw(key, IntToStr(i));
end;

procedure JsonKeyValueSmart(const key, val, propType: string);
var v: string;
begin
  v := Trim(val);

  if (Pos('Bool', propType) > 0) and LooksLikeBool(v) then begin
    JsonKeyRaw(key, ToJsonBool(v));
    Exit;
  end;
  if (Pos('Int', propType) > 0) and LooksLikeInt(v) then begin
    JsonKeyRaw(key, v);
    Exit;
  end;
  if (Pos('Float', propType) > 0) and LooksLikeFloat(v) then begin
    JsonKeyRaw(key, v);
    Exit;
  end;

  // Object refs / Keywords etc. often come back as "SomeForm [KYWD:XXXXXXXX]" or "XXXXXXXX"
  // Keep as string unless numeric/bool/float.
  if LooksLikeBool(v) then JsonKeyRaw(key, ToJsonBool(v))
  else if LooksLikeInt(v) then JsonKeyRaw(key, v)
  else if LooksLikeFloat(v) then JsonKeyRaw(key, v)
  else JsonKeyRaw(key, Quote(v));
end;

procedure ExportMemberValueAsJson(const member: IInterface);
var
  mName: string;
  mVal, tv: string;
  mValNode: IInterface;
begin
  // Starfield VMAD: Member has memberName + Value union
  mName := GetEditValueIfPath(member, 'memberName');
  if mName = '' then mName := GetElementEditValues(member, 'memberName');
  if mName = '' then mName := Name(member);

  // Prefer Value subtree if present
  mValNode := SafePath(member, 'Value');
  if Assigned(mValNode) then mVal := GetBestValueString(member)
  else mVal := GetBestValueString(member);

  tv := Trim(mVal);

  if LooksLikeBool(tv) then JsonKeyRaw(mName, ToJsonBool(tv))
  else if LooksLikeInt(tv) then JsonKeyRaw(mName, tv)
  else if LooksLikeFloat(tv) then JsonKeyRaw(mName, tv)
  else JsonKeyString(mName, mVal);
end;

procedure ExportStructNodeAsObject(structNode: IInterface);
var
  members, mem: IInterface;
  i, n: Integer;
begin
  JsonBeginObject;

  // Some builds show members directly; others under "Members"
  members := SafePath(structNode, 'Members');
  if not Assigned(members) then
    members := FindFirstDescByExactName(structNode, 'Members');

  if Assigned(members) then begin
    n := ElementCount(members);
    for i := 0 to n - 1 do begin
      mem := ElementByIndex(members, i);
      ExportMemberValueAsJson(mem);
    end;
  end else begin
    // Common in SF: structNode itself contains "Member #n"
    n := ElementCount(structNode);
    for i := 0 to n - 1 do begin
      mem := ElementByIndex(structNode, i);
      // Only process elements that look like Member blocks
      if Pos('Member', Name(mem)) > 0 then
        ExportMemberValueAsJson(mem);
    end;
  end;

  JsonEndObject;
end;

procedure ExportArrayOfStruct(prop: IInterface);
var
  arr, item, structNode: IInterface;
  i, n: Integer;
begin
  // Find the actual array container (SF varies between these)
  arr := SafePath(prop, 'Value\Array of Struct');
  if not Assigned(arr) then arr := SafePath(prop, 'Value\Array');
  if not Assigned(arr) then arr := SafePath(prop, 'Array');
  if not Assigned(arr) then arr := FindFirstDescByExactName(prop, 'Array of Struct');
  if not Assigned(arr) then arr := FindFirstDescByExactName(prop, 'Array');

  EnsureCommaIfNeeded;
  AddLine(Quote('value') + ': [');
  MarkWroteItem;
  Inc(gIndent);
  PushContainer;

  if Assigned(arr) then begin
    n := ElementCount(arr);
    for i := 0 to n - 1 do begin
      item := ElementByIndex(arr, i);

      // For Array of Struct, each item usually contains "Struct"
      structNode := SafePath(item, 'Struct');
      if not Assigned(structNode) then structNode := SafePath(item, 'Value\Struct');
      if not Assigned(structNode) then structNode := FindFirstDescByExactName(item, 'Struct');
      if not Assigned(structNode) then structNode := item; // fallback: treat item as struct root

      ExportStructNodeAsObject(structNode);
    end;
  end;

  PopContainer;
  Dec(gIndent);
  AddLine(']');
end;

procedure ExportArrayPrimitive(prop: IInterface);
var
  arr, item: IInterface;
  i, n: Integer;
  v, tv: string;
begin
  arr := SafePath(prop, 'Value\Array');
  if not Assigned(arr) then arr := SafePath(prop, 'Array');
  if not Assigned(arr) then arr := FindFirstDescByExactName(prop, 'Array');

  EnsureCommaIfNeeded;
  AddLine(Quote('value') + ': [');
  MarkWroteItem;
  Inc(gIndent);
  PushContainer;

  if Assigned(arr) then begin
    n := ElementCount(arr);
    for i := 0 to n - 1 do begin
      item := ElementByIndex(arr, i);
      v := GetBestValueString(item);
      tv := Trim(v);

      EnsureCommaIfNeeded;
      if LooksLikeBool(tv) then AddLine(ToJsonBool(tv))
      else if LooksLikeInt(tv) then AddLine(tv)
      else if LooksLikeFloat(tv) then AddLine(tv)
      else AddLine(Quote(v));
      MarkWroteItem;
    end;
  end;

  PopContainer;
  Dec(gIndent);
  AddLine(']');
end;

procedure ExportSingleStruct(prop: IInterface);
var
  s: IInterface;
begin
  s := SafePath(prop, 'Value\Struct');
  if not Assigned(s) then s := SafePath(prop, 'Struct');
  if not Assigned(s) then s := FindFirstDescByExactName(prop, 'Struct');

  EnsureCommaIfNeeded;
  AddLine(Quote('value') + ': ');
  MarkWroteItem;

  // We wrote the key line; now write the object itself on next lines
  // by emitting an object and relying on commas handled by container stack.
  // (So do NOT call EnsureCommaIfNeeded here again.)
  ExportStructNodeAsObject(s);
end;

procedure ExportPropertyToJson(prop: IInterface);
var
  propName, propType: string;
  isArr, isStruct: Boolean;
  v: string;
begin
  Inc(gPropCount);

  propName := GetPropNameString(prop);
  propType := GetPropTypeString(prop);

  isArr := IsArrayProp(prop, propType);
  isStruct := IsStructProp(prop, propType);

  JsonBeginObject;
  JsonKeyString('name', propName);
  JsonKeyString('type', propType);

  if isArr and (Pos('Struct', propType) > 0) then begin
    ExportArrayOfStruct(prop);
  end else if isStruct then begin
    ExportSingleStruct(prop);
  end else if isArr then begin
    ExportArrayPrimitive(prop);
  end else begin
    v := GetBestValueString(prop);
    JsonKeyValueSmart('value', v, propType);
  end;

  JsonEndObject;
end;

procedure ExportScriptBlockToJson(scriptContainer: IInterface);
var
  i, sc: Integer;
  script, props, prop: IInterface;
  scriptName: string;
  j, pc: Integer;
begin
  if not Assigned(scriptContainer) then Exit;

  sc := ElementCount(scriptContainer);
  for i := 0 to sc - 1 do begin
    script := ElementByIndex(scriptContainer, i);

    Inc(gScriptCount);
    scriptName := GetScriptNameString(script);

    JsonBeginObject;
    JsonKeyString('name', scriptName);

    // NEW: stable selector for reimport + CSV splitting
    JsonKeyRaw('script_index', IntToStr(i));

    props := SafePath(script, 'Properties');
    if Assigned(props) then begin
      EnsureCommaIfNeeded;
      AddLine(Quote('properties') + ': [');
      MarkWroteItem;
      Inc(gIndent);
      PushContainer;

      pc := ElementCount(props);
      for j := 0 to pc - 1 do begin
        prop := ElementByIndex(props, j);
        ExportPropertyToJson(prop);
      end;

      PopContainer;
      Dec(gIndent);
      AddLine(']');
    end else begin
      JsonKeyRaw('properties', '[]');
    end;

    JsonEndObject;
  end;
end;


procedure ExportAliasesToJson(quest: IInterface);
var
  vmad, aliases, aliasRec, aliasScripts: IInterface;
  i, ac: Integer;
  aliasId, aliasName: string;
begin
  vmad := SafePath(quest, 'VMAD - Virtual Machine Adapter');
  aliases := nil;
  if Assigned(vmad) then
    aliases := SafePath(vmad, 'Aliases');

  if not Assigned(aliases) then begin
    JsonKeyRaw('aliases', '[]');
    Exit;
  end;

  EnsureCommaIfNeeded;
  AddLine(Quote('aliases') + ': [');
  MarkWroteItem;
  Inc(gIndent);
  PushContainer;

  ac := ElementCount(aliases);
  for i := 0 to ac - 1 do begin
    aliasRec := ElementByIndex(aliases, i);

    // Alias name/id vary by view; keep both best-effort
    aliasId := GetEditValueIfPath(aliasRec, 'ALID');
    if aliasId = '' then aliasId := GetEditValueIfPath(aliasRec, 'ALID - Alias ID');
    aliasName := GetEditValueIfPath(aliasRec, 'Alias Name');
    if aliasName = '' then aliasName := Name(aliasRec);

    Inc(gAliasCount);

    JsonBeginObject;
    JsonKeyString('alias_id', aliasId);
    JsonKeyString('alias_name', aliasName);

    // Alias scripts container
    aliasScripts := SafePath(aliasRec, 'Alias Scripts');
    if not Assigned(aliasScripts) then
      aliasScripts := FindFirstDescByExactName(aliasRec, 'Alias Scripts');

    if Assigned(aliasScripts) then begin
      EnsureCommaIfNeeded;
      AddLine(Quote('scripts') + ': [');
      MarkWroteItem;
      Inc(gIndent);
      PushContainer;

      ExportScriptBlockToJson(aliasScripts);

      PopContainer;
      Dec(gIndent);
      AddLine(']');
    end else begin
      JsonKeyRaw('scripts', '[]');
    end;

    JsonEndObject;
  end;

  PopContainer;
  Dec(gIndent);
  AddLine(']');
end;

procedure ExportQuestToJson(quest: IInterface);
var
  questFID, questEDID: string;
  vmad, scripts: IInterface;
begin
  Inc(gQuestCount);

  questFID := IntToHex(GetLoadOrderFormID(quest), 8);
  questEDID := EditorID(quest);

  JsonBeginObject;
  JsonKeyString('formid', questFID);
  JsonKeyString('edid', questEDID);
  JsonKeyString('signature', Signature(quest));     // "QUST"
  JsonKeyString('name', Name(quest));               // full xEdit display name
  JsonKeyString('file', Name(GetFile(quest)));      // "[01] testquestcopy.esm" style (from the record)


  // Quest-level scripts
  vmad := SafePath(quest, 'VMAD - Virtual Machine Adapter');
  scripts := nil;
  if Assigned(vmad) then scripts := SafePath(vmad, 'Scripts');

  if Assigned(scripts) then begin
    EnsureCommaIfNeeded;
    AddLine(Quote('scripts') + ': [');
    MarkWroteItem;
    Inc(gIndent);
    PushContainer;

    ExportScriptBlockToJson(scripts);

    PopContainer;
    Dec(gIndent);
    AddLine(']');
  end else begin
    JsonKeyRaw('scripts', '[]');
  end;

  // Alias scripts (VMAD\Aliases\Alias\Alias Scripts)
  ExportAliasesToJson(quest);

  JsonEndObject;
end;

function Process(e: IInterface): integer;
var f: IInterface; fn: string;
begin
  Result := 0;

  if not gSourceFileSet then begin
    f := GetFile(e);
    fn := Name(f);
    gJson[gSourceFileLineIndex] := IndentStr + '"source_file": ' + Quote(fn) + ',';
    gSourceFileSet := True;
  end;

  if Signature(e) <> 'QUST' then Exit;
  ExportQuestToJson(e);
end;

function Initialize: integer;
var baseName: string;
begin
  Result := 0;

  gQuestCount := 0;
  gScriptCount := 0;
  gPropCount := 0;
  gAliasCount := 0;

  gIndent := 0;
  gJson := TStringList.Create;
  gNeedComma := TStringList.Create;

  baseName := 'VMAD_Quests_' + FormatDateTime('yyyymmdd_hhnnss', Now) + '.json';
  gOutPath := ProgramPath + baseName;

  AddLine('{');
  Inc(gIndent);
  PushContainer;

  // Avoid helper calls here (older JvInterpreter builds can choke)
  AddLine('"format": "Starfield-VMAD-2",');

  gSourceFileLineIndex := gJson.Count;
  AddLine('"source_file": "",');
  gSourceFileSet := False;

  EnsureCommaIfNeeded;
  AddLine('"quests": [');
  MarkWroteItem;
  Inc(gIndent);
  PushContainer;
end;

function Finalize: integer;
begin
  Result := 0;

  PopContainer;
  Dec(gIndent);
  AddLine(']');

  PopContainer;
  Dec(gIndent);
  AddLine('}');

  gJson.SaveToFile(gOutPath);

  AddMessage('Exported JSON quests=' + IntToStr(gQuestCount) +
             ' aliases=' + IntToStr(gAliasCount) +
             ' scripts=' + IntToStr(gScriptCount) +
             ' properties=' + IntToStr(gPropCount));
  AddMessage('Wrote JSON: ' + gOutPath);

  gNeedComma.Free;
  gJson.Free;
end;

end.
