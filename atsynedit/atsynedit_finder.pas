unit ATSynEdit_Finder;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Dialogs, Forms,
  Math,
  RegExpr, //must be with {$define Unicode}
  ATSynEdit,
  ATSynEdit_Carets,
  ATStringProc,
  ATStringProc_TextBuffer;

type
  TATFinderProgress = procedure(Sender: TObject; ACurPos, AMaxPos: integer;
    var AContinue: boolean) of object;
  TATFinderFound = procedure(Sender: TObject; APos1, APos2: TPoint) of object;
  TATFinderConfirmReplace = procedure(Sender: TObject;
    APos1, APos2: TPoint; AForMany: boolean;
    var AConfirm, AContinue: boolean) of object;

type
  { TATTextFinder }

  TATTextFinder = class
  private
    FMatchPos: integer;
    FMatchLen: integer;
    FOnProgress: TATFinderProgress;
    FOnBadRegex: TNotifyEvent;
    function DoCountMatchesRegex(FromPos: integer; AWithEvent: boolean): integer;
    function DoCountMatchesUsual(FromPos: integer; AWithEvent: boolean): Integer;
    function DoFindMatchRegex(FromPos: integer; var MatchPos, MatchLen: integer): boolean;
    function DoFindMatchUsual(FromPos: integer): Integer;
    function IsMatchUsual(APos: integer): boolean;
  protected
    procedure DoOnFound; virtual;
  public
    StrText: UnicodeString;
    StrFind: UnicodeString;
    StrReplace: UnicodeString;
    StrReplacement: UnicodeString; //for regex
    OptBack: boolean; //for non-regex
    OptWords: boolean; //for non-regex
    OptCase: boolean; //for regex and usual
    OptRegex: boolean;
    OptWrapped: boolean;
    constructor Create;
    destructor Destroy; override;
    function FindMatch(ANext: boolean; ASkipLen: integer; AStartPos: integer): boolean;
    property MatchPos: integer read FMatchPos; //have meaning if FindMatch returned True
    property MatchLen: integer read FMatchLen; //too
    property OnProgress: TATFinderProgress read FOnProgress write FOnProgress;
    property OnBadRegex: TNotifyEvent read FOnBadRegex write FOnBadRegex;
  end;

type
  { TATEditorFinder }

  TATEditorFinder = class(TATTextFinder)
  private
    FBuffer: TATStringBuffer;
    FEditor: TATSynEdit;
    FSkipLen: integer;
    FOnFound: TATFinderFound;
    FOnConfirmReplace: TATFinderConfirmReplace;
    function DoFindOrReplace_Internal(ANext, AReplace, AForMany: boolean; out
      AChanged: boolean; AStartPos: integer): boolean;
    procedure DoFixCaretSelectionDirection;
    procedure DoReplaceTextInEditor(P1, P2: TPoint);
    function GetOffsetOfCaret: integer;
    function GetOffsetStartPos: integer;
  protected
    procedure DoOnFound; override;
  public
    OptFromCaret: boolean;
    OptConfirmReplace: boolean;
    constructor Create;
    destructor Destroy; override;
    procedure UpdateBuffer;
    property Editor: TATSynEdit read FEditor write FEditor;
    property OnFound: TATFinderFound read FOnFound write FOnFound;
    property OnConfirmReplace: TATFinderConfirmReplace read FOnConfirmReplace write FOnConfirmReplace;
    function DoFindOrReplace(ANext, AReplace, AForMany: boolean; out AChanged: boolean): boolean;
    function DoReplaceSelectedMatch: boolean;
    function DoCountAll(AWithEvent: boolean): integer;
    function DoReplaceAll: integer;
    function IsSelectionStartsAtFoundMatch: boolean;
 end;


implementation

function IsWordChar(ch: Widechar): boolean;
begin
  Result:= ATStringProc.IsCharWord(ch, '');
end;

function SRegexReplaceEscapedTabs(const AStr: string): string;
begin
  Result:= AStr;
  Result:= StringReplace(Result, '\\', #1, [rfReplaceAll]);
  Result:= StringReplace(Result, '\t', #9, [rfReplaceAll]);
  Result:= StringReplace(Result, #1, '\\', [rfReplaceAll]);
end;


function TATTextFinder.IsMatchUsual(APos: integer): boolean;
var
  LenF, LastPos: integer;
begin
  Result:= false;
  if StrFind='' then exit;
  if StrText='' then exit;

  LenF:= Length(StrFind);
  LastPos:= Length(StrText)-LenF+1;

  if OptCase then
    Result:= CompareMem(@StrFind[1], @StrText[APos], LenF*2)
  else
    Result:=
      UnicodeLowerCase(StrFind) =
      UnicodeLowerCase(Copy(StrText, APos, LenF));

  if Result then
    if OptWords then
      Result:=
        ((APos <= 1) or (not IsWordChar(StrText[APos - 1]))) and
        ((APos >= LastPos) or (not IsWordChar(StrText[APos + LenF])));
end;

procedure TATTextFinder.DoOnFound;
begin
  //
end;

function TATTextFinder.DoFindMatchUsual(FromPos: integer): Integer;
var
  LastPos, i: integer;
begin
  Result:= 0;
  if StrText='' then exit;
  if StrFind='' then exit;
  LastPos:= Length(StrText) - Length(StrFind) + 1;

  if not OptBack then
    for i:= FromPos to LastPos do
    begin
      if IsMatchUsual(i) then
      begin
        Result:= i;
        Break
      end;
    end
  else
    for i:= FromPos downto 1 do
    begin
     if IsMatchUsual(i) then
      begin
        Result:= i;
        Break
      end;
    end;
end;

function TATTextFinder.DoFindMatchRegex(FromPos: integer; var MatchPos,
  MatchLen: integer): boolean;
var
  Obj: TRegExpr;
begin
  Result:= false;
  if StrText='' then exit;
  if StrFind='' then exit;

  Obj:= TRegExpr.Create;
  try
    Obj.ModifierS:= false; //don't catch all text by .*
    Obj.ModifierM:= true; //allow to work with ^$
    Obj.ModifierI:= not OptCase;

    try
      Obj.Expression:= StrFind;
      Obj.InputString:= StrText;
      Result:= Obj.ExecPos(FromPos);
    except
      if Assigned(FOnBadRegex) then
        FOnBadRegex(Self);
      Result:= false;
    end;

    if Result then
    begin
      MatchPos:= Obj.MatchPos[0];
      MatchLen:= Obj.MatchLen[0];
      if StrReplace<>'' then
        StrReplacement:= Obj.Replace(Obj.Match[0], SRegexReplaceEscapedTabs(StrReplace), true);
    end;
  finally
    FreeAndNil(Obj);
  end;
end;

function TATTextFinder.DoCountMatchesUsual(FromPos: integer; AWithEvent: boolean
  ): Integer;
var
  LastPos, i: Integer;
  Ok: boolean;
begin
  Result:= 0;
  if StrText='' then exit;
  if StrFind='' then exit;
  LastPos:= Length(StrText) - Length(StrFind) + 1;

  for i:= FromPos to LastPos do
    if IsMatchUsual(i) then
    begin
      Inc(Result);
      if AWithEvent then
      begin
        FMatchPos:= i;
        FMatchLen:= Length(StrFind);
        DoOnFound;
      end;

      if Assigned(FOnProgress) then
      begin
        Ok:= true;
        FOnProgress(Self, i, LastPos, Ok);
        if not Ok then Break;
      end;
    end;
end;

function TATTextFinder.DoCountMatchesRegex(FromPos: integer; AWithEvent: boolean
  ): integer;
var
  Obj: TRegExpr;
  Ok: boolean;
begin
  Result:= 0;
  if StrFind='' then exit;
  if StrText='' then exit;

  Obj:= TRegExpr.Create;
  try
    Obj.ModifierS:= false;
    Obj.ModifierM:= true;
    Obj.ModifierI:= not OptCase;

    try
      Obj.Expression:= StrFind;
      Obj.InputString:= StrText;
      Ok:= Obj.ExecPos(FromPos);
    except
      if Assigned(FOnBadRegex) then
        FOnBadRegex(Self);
      Result:= 0;
      Exit;
    end;

    if Ok then
    begin
      Inc(Result);
      if AWithEvent then
      begin
        FMatchPos:= Obj.MatchPos[0];
        FMatchLen:= Obj.MatchLen[0];
        DoOnFound;
      end;

      while Obj.ExecNext do
      begin
        Inc(Result);
        if AWithEvent then
        begin
          FMatchPos:= Obj.MatchPos[0];
          FMatchLen:= Obj.MatchLen[0];
          DoOnFound;
        end;

        if Assigned(FOnProgress) then
        begin
          Ok:= true;
          FOnProgress(Self, Obj.MatchPos[0], Length(StrText), Ok);
          if not Ok then Break;
        end;
      end;
    end;
  finally
    FreeAndNil(Obj);
  end;
end;

procedure TATEditorFinder.UpdateBuffer;
var
  Lens: TList;
  i: integer;
begin
  Lens:= TList.Create;
  try
    Lens.Clear;
    for i:= 0 to FEditor.Strings.Count-1 do
      Lens.Add(pointer(Length(FEditor.Strings.Lines[i])));
    FBuffer.Setup(FEditor.Strings.TextString, Lens, 1);
  finally
    FreeAndNil(Lens);
  end;

  StrText:= FBuffer.FText;
end;

constructor TATEditorFinder.Create;
begin
  inherited;
  FEditor:= nil;
  FBuffer:= TATStringBuffer.Create;
  OptFromCaret:= false;
  OptConfirmReplace:= false;
end;

destructor TATEditorFinder.Destroy;
begin
  FEditor:= nil;
  FreeAndNil(FBuffer);
  inherited;
end;

function TATEditorFinder.GetOffsetOfCaret: integer;
var
  Pnt: TPoint;
begin
  with FEditor.Carets[0] do
  begin
    Pnt.X:= PosX;
    Pnt.Y:= PosY;
  end;

  Result:= FBuffer.CaretToStr(Pnt);
  Inc(Result); //was 0-based

  //find-back must goto previous match
  if OptBack then
    Dec(Result, Length(StrFind));

  if Result<1 then
    Result:= 1;
end;

function TATEditorFinder.DoCountAll(AWithEvent: boolean): integer;
begin
  UpdateBuffer;
  if OptRegex then
    Result:= DoCountMatchesRegex(1, AWithEvent)
  else
    Result:= DoCountMatchesUsual(1, AWithEvent);
end;

function TATEditorFinder.DoReplaceAll: integer;
var
  Ok, Changed: boolean;
begin
  Result:= 0;
  if DoFindOrReplace(false, true, true, Changed) then
  begin
    if Changed then Inc(Result);
    while DoFindOrReplace(true, true, true, Changed) do
    begin
      if Changed then Inc(Result);
      if Assigned(FOnProgress) then
      begin
        Ok:= true;
        FOnProgress(Self, FMatchPos, Length(StrText), Ok);
        if not Ok then Break;
      end;
    end;
  end;
end;

procedure TATEditorFinder.DoReplaceTextInEditor(P1, P2: TPoint);
var
  Shift, PosAfter: TPoint;
  Str: UnicodeString;
begin
  if OptRegex then
    Str:= StrReplacement
  else
    Str:= StrReplace;

  FEditor.Strings.BeginUndoGroup;
  FEditor.Strings.TextDeleteRange(P1.X, P1.Y, P2.X, P2.Y, Shift, PosAfter);
  FEditor.Strings.TextInsert(P1.X, P1.Y, Str, false, Shift, PosAfter);
  FEditor.Strings.EndUndoGroup;
end;

function TATEditorFinder.GetOffsetStartPos: integer;
begin
  if OptFromCaret then
    Result:= GetOffsetOfCaret
  else
  if OptRegex then
    Result:= 1
  else
  if OptBack then
    Result:= Length(StrText)
  else
    Result:= 1;
end;

procedure TATEditorFinder.DoFixCaretSelectionDirection;
var
  Caret: TATCaretItem;
  X1, Y1, X2, Y2: integer;
  bSel: boolean;
begin
  if FEditor.Carets.Count=0 then exit;
  Caret:= FEditor.Carets[0];
  Caret.GetRange(X1, Y1, X2, Y2, bSel);
  if not bSel then exit;

  if OptBack then
  begin
    Caret.PosX:= X1;
    Caret.PosY:= Y1;
    Caret.EndX:= X2;
    Caret.EndY:= Y2;
  end
  else
  begin
    Caret.PosX:= X2;
    Caret.PosY:= Y2;
    Caret.EndX:= X1;
    Caret.EndY:= Y1;
  end;
end;

function TATEditorFinder.DoFindOrReplace(ANext, AReplace, AForMany: boolean;
  out AChanged: boolean): boolean;
var
  NStartPos: integer;
begin
  Result:= false;
  AChanged:= false;

  if not Assigned(FEditor) then
  begin
    Showmessage('Finder.Editor not set');
    Exit
  end;
  if StrFind='' then
  begin
    Showmessage('Finder.StrFind not set');
    Exit
  end;
  if FEditor.Carets.Count=0 then
  begin
    Showmessage('Editor has not caret');
    Exit
  end;

  if AReplace and FEditor.ModeReadOnly then exit;
  if OptRegex then OptBack:= false;

  DoFixCaretSelectionDirection;

  NStartPos:= GetOffsetStartPos;
  Result:= DoFindOrReplace_Internal(ANext, AReplace, AForMany, AChanged, NStartPos);

  if not Result and OptWrapped then
    if (not OptBack and (NStartPos>1)) or
       (OptBack and (NStartPos<Length(StrText))) then
    begin
      //we must have AReplace=false
      //(if not, need more actions: don't allow to replace in wrapped part if too big pos)
      //
      if DoFindOrReplace_Internal(ANext, false, AForMany, AChanged,
        IfThen(not OptBack, 1, Length(StrText))) then
      begin
        Result:= (not OptBack and (MatchPos<NStartPos)) or
                 (OptBack and (MatchPos>NStartPos));
        if not Result then
        begin
          FMatchPos:= -1;
          FMatchLen:= 0;
        end;
      end;
    end;
end;


function TATEditorFinder.DoFindOrReplace_Internal(ANext, AReplace, AForMany: boolean;
  out AChanged: boolean; AStartPos: integer): boolean;
  //function usually called 1 time in outer func,
  //or 1-2 times if OptWrap=true
var
  P1, P2: TPoint;
  Cfm, CfmCont: boolean;
begin
  AChanged:= false;
  Result:= FindMatch(ANext, FSkipLen, AStartPos);
  FSkipLen:= FMatchLen;

  if Result then
  begin
    P1:= FBuffer.StrToCaret(MatchPos-1);
    P2:= FBuffer.StrToCaret(MatchPos-1+MatchLen);
    FEditor.DoCaretSingle(P1.X, P1.Y);

    if AReplace then
    begin
      Cfm:= true;
      CfmCont:= true;

      if OptConfirmReplace then
        if Assigned(FOnConfirmReplace) then
          FOnConfirmReplace(Self, P1, P2, AForMany, Cfm, CfmCont);

      if not CfmCont then
      begin
        Result:= false;
        Exit;
      end;

      if Cfm then
      begin
        DoReplaceTextInEditor(P1, P2);
        UpdateBuffer;

        if OptRegex then
          FSkipLen:= Length(StrReplacement)
        else
          FSkipLen:= Length(StrReplace);
        AChanged:= true;
      end;
    end;

    if AReplace then
      //don't select
      FEditor.DoCaretSingle(P1.X, P1.Y)
    else
    //select to right (find forward) or to left (find back)
    if OptBack then
      FEditor.DoCaretSingle(P1.X, P1.Y, P2.X, P2.Y, true)
    else
      FEditor.DoCaretSingle(P2.X, P2.Y, P1.X, P1.Y, true);
  end;
end;

function TATEditorFinder.IsSelectionStartsAtFoundMatch: boolean;
var
  Caret: TATCaretItem;
  X1, Y1, X2, Y2: integer;
  P1: TPoint;
  NPos: integer;
  bSel: boolean;
begin
  Result:= false;
  if FEditor.Carets.Count=0 then exit;
  Caret:= FEditor.Carets[0];
  Caret.GetRange(X1, Y1, X2, Y2, bSel);
  if not bSel then exit;

  P1:= Point(X1, Y1);
  NPos:= FBuffer.CaretToStr(P1)+1;

  //allow to replace, also if selection = Strfind
  Result:= (NPos=FMatchPos) or
    ((StrFind<>'') and (FEditor.TextSelected=StrFind));
end;

function TATEditorFinder.DoReplaceSelectedMatch: boolean;
var
  Caret: TATCaretItem;
  P1, P2: TPoint;
  X1, Y1, X2, Y2: integer;
  bSel: boolean;
begin
  Result:= false;
  if not IsSelectionStartsAtFoundMatch then
  begin
    //Showmessage('Please call "Replace" for found match, which is selected');
    //do Find-next (from caret)
    DoFindOrReplace(false, false, false, bSel);
    exit;
  end;

  Caret:= FEditor.Carets[0];
  Caret.GetRange(X1, Y1, X2, Y2, bSel);
  if not bSel then exit;
  P1:= Point(X1, Y1);
  P2:= Point(X2, Y2);

  Caret.EndX:= -1;
  Caret.EndY:= -1;

  DoReplaceTextInEditor(P1, P2);
  UpdateBuffer;

  if OptRegex then
    FSkipLen:= Length(StrReplacement)
  else
    FSkipLen:= Length(StrReplace);
end;


constructor TATTextFinder.Create;
begin
  StrFind:= '';
  StrText:= '';
  StrReplace:= '';
  StrReplacement:= '';
  OptBack:= false;
  OptCase:= false;
  OptWords:= false;
  OptRegex:= false;
  FMatchPos:= 0;
  FMatchLen:= 0;
end;

destructor TATTextFinder.Destroy;
begin
  inherited Destroy;
end;

function TATTextFinder.FindMatch(ANext: boolean; ASkipLen: integer; AStartPos: integer): boolean;
var
  FromPos: integer;
begin
  Result:= false;
  if StrText='' then Exit;
  if StrFind='' then Exit;

  //regex code
  if OptRegex then
  begin
    if not ANext then
      FromPos:= AStartPos
    else
      FromPos:= FMatchPos+ASkipLen;
    Result:= DoFindMatchRegex(FromPos, FMatchPos, FMatchLen);
    if Result then DoOnFound;
    Exit
  end;

  //usual code
  if not ANext then
  begin
    FMatchPos:= AStartPos;
  end
  else
  begin
    if FMatchPos=0 then
      FMatchPos:= 1;
    if not OptBack then
      Inc(FMatchPos, ASkipLen)
    else
      Dec(FMatchPos, ASkipLen);
  end;

  FMatchPos:= DoFindMatchUsual(FMatchPos);
  Result:= FMatchPos>0;
  if Result then
  begin
    FMatchLen:= Length(StrFind);
    DoOnFound;
  end;
end;

procedure TATEditorFinder.DoOnFound;
var
  P1, P2: TPoint;
begin
  if Assigned(FOnFound) then
  begin
    P1:= FBuffer.StrToCaret(MatchPos-1);
    P2:= FBuffer.StrToCaret(MatchPos-1+MatchLen);
    FOnFound(Self, P1, P2);
  end;
end;

end.
