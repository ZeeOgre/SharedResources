unit importquestvmads;

interface
uses xEditAPI, SysUtils, Classes, DarkStarLib;

implementation

var
  gJsonPath: string;
  gJsonText: string;
  gDbg: Boolean;
  
  gQuestsProcessed: Integer;
  gScriptsProcessed: Integer;
  gAliasesProcessed: Integer;
  gPropertiesProcessed: Integer;
  
  gSkipNoFile: Integer;
  gSkipNoQuest: Integer;
  gSkipNoScript: Integer;
  gSkipNoAlias: Integer;
  gSkipBadProperty: Integer;

{ -------------------------------------------------------
  JSON parsing helpers
------------------------------------------------------- }

function ExtractJsonValue(const json, key: string): string;
var
  startPos, endPos: Integer;
  searchStr, valueStr: string;
begin
  Result := '';
  searchStr := '"' + key + '":';
  startPos := Pos(searchStr, json);
  if startPos = 0 then Exit;
  
  startPos := startPos + Length(searchStr);
  // Skip whitespace
  while (startPos <= Length(json)) and (json[startPos] in [' ', #9, #13, #10]) do
    Inc(startPos);
    
  if startPos > Length(json) then Exit;
  
  // Handle string values (quoted)
  if json[startPos] = '"' then begin
    Inc(startPos); // skip opening quote
    endPos := startPos;
    while (endPos <= Length(json)) and (json[endPos] <> '"') do begin
      if json[endPos] = '\' then Inc(endPos, 2) // skip escaped chars
      else Inc(endPos);
    end;
    if endPos <= Length(json) then
      Result := Copy(json, startPos, endPos - startPos);
  end
  // Handle numeric/boolean values
  else begin
    endPos := startPos;
    while (endPos <= Length(json)) and not (json[endPos] in [',', '}', ']', #13, #10]) do
      Inc(endPos);
    Result := Trim(Copy(json, startPos, endPos - startPos));
  end;
end;

function ExtractJsonArray(const json, arrayName: string): TStringList;
var
  startPos, endPos, braceCount: Integer;
  searchStr: string;
begin
  Result := TStringList.Create;
  searchStr := '"' + arrayName + '":';
  startPos := Pos(searchStr, json);
  if startPos = 0 then Exit;
  
  startPos := startPos + Length(searchStr);
  // Find opening bracket
  while (startPos <= Length(json)) and (json[startPos] <> '[') do
    Inc(startPos);
  if startPos > Length(json) then Exit;
  
  Inc(startPos); // skip opening bracket
  braceCount := 0;
  endPos := startPos;
  
  while endPos <= Length(json) do begin
    case json[endPos] of
      '{': Inc(braceCount);
      '}': Dec(braceCount);
      ']': if braceCount = 0 then Break;
    end;
    Inc(endPos);
  end;
  
  if endPos <= Length(json) then
    Result.Text := Copy(json, startPos, endPos - startPos - 1);
end;

function SplitJsonObjects(const jsonArray: string): TStringList;
var
  i, braceCount, start: Integer;
  inString: Boolean;
  current: string;
begin
  Result := TStringList.Create;
  if Trim(jsonArray) = '' then Exit;
  
  braceCount := 0;
  inString := False;
  start := 1;
  
  for i := 1 to Length(jsonArray) do begin
    case jsonArray[i] of
      '"': if (i = 1) or (jsonArray[i-1] <> '\') then inString := not inString;
      '{': if not inString then Inc(braceCount);
      '}': if not inString then begin
        Dec(braceCount);
        if braceCount = 0 then begin
          current := Trim(Copy(jsonArray, start, i - start + 1));
          if current <> '' then Result.Add(current);
          start := i + 1;
          // Skip comma and whitespace
          while (start <= Length(jsonArray)) and (jsonArray[start] in [',', ' ', #9, #13, #10]) do
            Inc(start);
        end;
      end;
    end;
  end;
end;

{ -------------------------------------------------------
  VMAD property helpers
------------------------------------------------------- }

function ParseFID(const s: string): Cardinal;
var t: string;
begin
  Result := 0;
  t := UpperCase(Trim(s));
  if t = '' then Exit;
  if (Length(t) >= 2) and ((Copy(t,1,2)='0X')) then
    t := Copy(t,3,Length(t));
  try
    Result := StrToInt('$'+t);
  except
    Result := 0;
  end;
end;

function FID8(const fid: Cardinal): string;
begin
  Result := IntToHex(fid, 8);
end;

procedure EnsureVMADStructure(questRec: IInterface);
var vmadEl: IInterface;
begin
  vmadEl := ElementByPath(questRec, 'VMAD - Virtual Machine Adapter');
  if not Assigned(vmadEl) then begin
    Add(questRec, 'VMAD - Virtual Machine Adapter', True);
    vmadEl := ElementByPath(questRec, 'VMAD - Virtual Machine Adapter');
  end;
  
  if not Assigned(ElementByPath(vmadEl, 'Scripts')) then
    Add(vmadEl, 'Scripts', True);
    
  if not Assigned(ElementByPath(vmadEl, 'Aliases')) then
    Add(vmadEl, 'Aliases', True);
end;

function FindOrCreateScript(parentEl: IInterface; const scriptName: string; scriptIndex: Integer): IInterface;
var
  scriptsEl, scriptEl: IInterface;
  i: Integer;
begin
  Result := nil;
  scriptsEl := ElementByPath(parentEl, 'Scripts');
  if not Assigned(scriptsEl) then begin
    Add(parentEl, 'Scripts', True);
    scriptsEl := ElementByPath(parentEl, 'Scripts');
  end;
  
  if not Assigned(scriptsEl) then Exit;
  
  // Look for existing script by name or index
  for i := 0 to ElementCount(scriptsEl) - 1 do begin
    scriptEl := ElementByIndex(scriptsEl, i);
    if GetElementEditValues(scriptEl, 'scriptName') = scriptName then begin
      Result := scriptEl;
      Exit;
    end;
  end;
  
  // Create new script
  Result := Add(scriptsEl, '', True);
  if Assigned(Result) then begin
    SetElementEditValues(Result, 'scriptName', scriptName);
    if not Assigned(ElementByPath(Result, 'Properties')) then
      Add(Result, 'Properties', True);
  end;
end;

function FindOrCreateProperty(scriptEl: IInterface; const propName, propType: string): IInterface;
var
  propsEl, propEl: IInterface;
  i: Integer;
begin
  Result := nil;
  propsEl := ElementByPath(scriptEl, 'Properties');
  if not Assigned(propsEl) then begin
    Add(scriptEl, 'Properties', True);
    propsEl := ElementByPath(scriptEl, 'Properties');
  end;
  
  if not Assigned(propsEl) then Exit;
  
  // Look for existing property by name
  for i := 0 to ElementCount(propsEl) - 1 do begin
    propEl := ElementByIndex(propsEl, i);
    if GetElementEditValues(propEl, 'propertyName') = propName then begin
      Result := propEl;
      Exit;
    end;
  end;
  
  // Create new property
  Result := Add(propsEl, '', True);
  if Assigned(Result) then begin
    SetElementEditValues(Result, 'propertyName', propName);
    SetElementEditValues(Result, 'Type', propType);
  end;
end;

procedure ApplyPropertyValue(propEl: IInterface; const propType, valueJson: string);
var
  valueEl: IInterface;
  fid: Cardinal;
  intVal: Integer;
  floatVal: Double;
  boolVal: Boolean;
begin
  if not Assigned(propEl) then Exit;
  
  valueEl := ElementByPath(propEl, 'Value');
  if not Assigned(valueEl) then begin
    Add(propEl, 'Value', True);
    valueEl := ElementByPath(propEl, 'Value');
  end;
  
  if not Assigned(valueEl) then Exit;
  
  // Handle different property types
  if (Pos('Object', propType) > 0) or (Pos('Form', propType) > 0) then begin
    // Object/Form reference - parse as FID
    fid := ParseFID(valueJson);
    SetEditValue(valueEl, FID8(fid));
  end
  else if Pos('Int', propType) > 0 then begin
    // Integer value
    try
      intVal := StrToInt(Trim(valueJson));
      SetEditValue(valueEl, IntToStr(intVal));
    except
      SetEditValue(valueEl, '0');
    end;
  end
  else if Pos('Float', propType) > 0 then begin
    // Float value
    try
      floatVal := StrToFloat(Trim(valueJson));
      SetEditValue(valueEl, FloatToStr(floatVal));
    except
      SetEditValue(valueEl, '0.0');
    end;
  end
  else if Pos('Bool', propType) > 0 then begin
    // Boolean value
    boolVal := (UpperCase(Trim(valueJson)) = 'TRUE') or (Trim(valueJson) = '1');
    SetEditValue(valueEl, BoolToStr(boolVal, True));
  end
  else if Pos('String', propType) > 0 then begin
    // String value - remove quotes if present
    if (Length(valueJson) >= 2) and (valueJson[1] = '"') and (valueJson[Length(valueJson)] = '"') then
      SetEditValue(valueEl, Copy(valueJson, 2, Length(valueJson) - 2))
    else
      SetEditValue(valueEl, valueJson);
  end
  else if Pos('Array', propType) > 0 then begin
    // Array types need special handling - for now just store as string
    // TODO: Implement proper array parsing based on element type
    AddMessage('WARN: Array property type not fully implemented: ' + propType);
    SetEditValue(valueEl, valueJson);
  end
  else begin
    // Unknown type - store as string
    SetEditValue(valueEl, valueJson);
  end;
end;

{ -------------------------------------------------------
  Quest processing
------------------------------------------------------- }

procedure ProcessQuestScript(questRec: IInterface; const scriptJson: string);
var
  scriptName, propName, propType, valueJson: string;
  scriptIndex: Integer;
  scriptEl, propEl: IInterface;
  propsArray, propObjects: TStringList;
  i: Integer;
begin
  scriptName := ExtractJsonValue(scriptJson, 'name');
  scriptIndex := StrToIntDef(ExtractJsonValue(scriptJson, 'script_index'), 0);
  
  if scriptName = '' then begin
    Inc(gSkipNoScript);
    Exit;
  end;
  
  scriptEl := FindOrCreateScript(ElementByPath(questRec, 'VMAD - Virtual Machine Adapter'), scriptName, scriptIndex);
  if not Assigned(scriptEl) then begin
    Inc(gSkipNoScript);
    Exit;
  end;
  
  Inc(gScriptsProcessed);
  if gDbg then
    AddMessage('Processing quest script: ' + scriptName);
  
  // Process properties
  propsArray := ExtractJsonArray(scriptJson, 'properties');
  try
    propObjects := SplitJsonObjects(propsArray.Text);
    try
      for i := 0 to propObjects.Count - 1 do begin
        propName := ExtractJsonValue(propObjects[i], 'name');
        propType := ExtractJsonValue(propObjects[i], 'type');
        valueJson := ExtractJsonValue(propObjects[i], 'value');
        
        if (propName = '') or (propType = '') then begin
          Inc(gSkipBadProperty);
          Continue;
        end;
        
        propEl := FindOrCreateProperty(scriptEl, propName, propType);
        if Assigned(propEl) then begin
          ApplyPropertyValue(propEl, propType, valueJson);
          Inc(gPropertiesProcessed);
          if gDbg then
            AddMessage('  Property: ' + propName + ' = ' + valueJson);
        end else begin
          Inc(gSkipBadProperty);
        end;
      end;
    finally
      propObjects.Free;
    end;
  finally
    propsArray.Free;
  end;
end;

procedure ProcessQuestAlias(questRec: IInterface; const aliasJson: string);
var
  aliasIndex: Integer;
  aliasName: string;
  vmadEl, aliasesEl, aliasEl: IInterface;
  scriptsArray, scriptObjects: TStringList;
  i: Integer;
begin
  aliasIndex := StrToIntDef(ExtractJsonValue(aliasJson, 'alias_index'), -1);
  aliasName := ExtractJsonValue(aliasJson, 'alias_name');
  
  if aliasIndex < 0 then begin
    Inc(gSkipNoAlias);
    Exit;
  end;
  
  vmadEl := ElementByPath(questRec, 'VMAD - Virtual Machine Adapter');
  aliasesEl := ElementByPath(vmadEl, 'Aliases');
  
  // Find or create alias by index
  while ElementCount(aliasesEl) <= aliasIndex do
    Add(aliasesEl, '', True);
    
  aliasEl := ElementByIndex(aliasesEl, aliasIndex);
  if not Assigned(aliasEl) then begin
    Inc(gSkipNoAlias);
    Exit;
  end;
  
  Inc(gAliasesProcessed);
  if gDbg then
    AddMessage('Processing alias [' + IntToStr(aliasIndex) + ']: ' + aliasName);
  
  // Process alias scripts
  scriptsArray := ExtractJsonArray(aliasJson, 'scripts');
  try
    scriptObjects := SplitJsonObjects(scriptsArray.Text);
    try
      for i := 0 to scriptObjects.Count - 1 do begin
        ProcessQuestScript(aliasEl, scriptObjects[i]); // Reuse script processing logic
      end;
    finally
      scriptObjects.Free;
    end;
  finally
    scriptsArray.Free;
  end;
end;

procedure ProcessQuest(const questJson: string);
var
  formidStr, edid: string;
  formid: Cardinal;
  questFile: IInterface;
  questRec: IInterface;
  scriptsArray, aliasesArray: TStringList;
  scriptObjects, aliasObjects: TStringList;
  i: Integer;
begin
  formidStr := ExtractJsonValue(questJson, 'formid');
  edid := ExtractJsonValue(questJson, 'edid');
  formid := ParseFID(formidStr);
  
  if formid = 0 then begin
    Inc(gSkipNoQuest);
    Exit;
  end;
  
  // Find the quest record
  questFile := FileByLoadOrder((formid shr 24) and $FF);
  if not Assigned(questFile) then begin
    Inc(gSkipNoFile);
    Exit;
  end;
  
  questRec := RecordByFormID(questFile, formid, True);
  if not Assigned(questRec) then begin
    Inc(gSkipNoQuest);
    Exit;
  end;
  
  Inc(gQuestsProcessed);
  AddMessage('Processing quest: ' + edid + ' [' + FID8(formid) + ']');
  
  // Ensure VMAD structure exists
  EnsureVMADStructure(questRec);
  
  // Process quest scripts
  scriptsArray := ExtractJsonArray(questJson, 'scripts');
  try
    scriptObjects := SplitJsonObjects(scriptsArray.Text);
    try
      for i := 0 to scriptObjects.Count - 1 do begin
        ProcessQuestScript(questRec, scriptObjects[i]);
      end;
    finally
      scriptObjects.Free;
    end;
  finally
    scriptsArray.Free;
  end;
  
  // Process aliases
  aliasesArray := ExtractJsonArray(questJson, 'aliases');
  try
    aliasObjects := SplitJsonObjects(aliasesArray.Text);
    try
      for i := 0 to aliasObjects.Count - 1 do begin
        ProcessQuestAlias(questRec, aliasObjects[i]);
      end;
    finally
      aliasObjects.Free;
    end;
  finally
    aliasesArray.Free;
  end;
end;

{ -------------------------------------------------------
  Main processing
------------------------------------------------------- }

procedure ProcessJsonFile;
var
  questsArray: TStringList;
  questObjects: TStringList;
  i: Integer;
begin
  questsArray := ExtractJsonArray(gJsonText, 'quests');
  try
    questObjects := SplitJsonObjects(questsArray.Text);
    try
      AddMessage('Found ' + IntToStr(questObjects.Count) + ' quests to process');
      
      for i := 0 to questObjects.Count - 1 do begin
        ProcessQuest(questObjects[i]);
      end;
    finally
      questObjects.Free;
    end;
  finally
    questsArray.Free;
  end;
end;

{ -------------------------------------------------------
  Entry point
------------------------------------------------------- }

function Initialize: Integer;
var
  jsonFile: TStringList;
begin
  Result := 0;
  
  gJsonPath := InputBox('JSON', 'Path to subset.updated.json', '');
  gJsonPath := DarkStarLib.StrReplace(Trim(gJsonPath), '"', ''); // accept quoted paths
  
  if not FileExists(gJsonPath) then begin
    AddMessage('JSON file not found: ' + gJsonPath);
    Exit(1);
  end;
  
  gDbg := True;
  
  gQuestsProcessed := 0;
  gScriptsProcessed := 0;
  gAliasesProcessed := 0;
  gPropertiesProcessed := 0;
  
  gSkipNoFile := 0;
  gSkipNoQuest := 0;
  gSkipNoScript := 0;
  gSkipNoAlias := 0;
  gSkipBadProperty := 0;
  
  // Load JSON file
  jsonFile := TStringList.Create;
  try
    jsonFile.LoadFromFile(gJsonPath);
    gJsonText := jsonFile.Text;
  finally
    jsonFile.Free;
  end;
  
  AddMessage('Loaded JSON: ' + gJsonPath);
  AddMessage('JSON size: ' + IntToStr(Length(gJsonText)) + ' characters');
  
  ProcessJsonFile;
  
  AddMessage(Format(
    'SUMMARY: quests=%d scripts=%d aliases=%d properties=%d | skips: noFile=%d noQuest=%d noScript=%d noAlias=%d badProperty=%d',
    [gQuestsProcessed, gScriptsProcessed, gAliasesProcessed, gPropertiesProcessed,
     gSkipNoFile, gSkipNoQuest, gSkipNoScript, gSkipNoAlias, gSkipBadProperty]
  ));
end;

end.