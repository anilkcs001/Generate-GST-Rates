codeunit 50000 "AK GST Rate Generator"
{
    var
        GSTSetup: Record "GST Setup";
        TaxSetupMatrixMgmt: Codeunit "Tax Setup Matrix Mgmt.";
        GlobalTaxType: Code[20];
        RangeAttribute: array[1000] of Boolean;
        AttributeID: array[1000] of Integer;
        AttributeCaption: array[1000] of Text;
        AttributeValue: array[1000] of Text;
        ColumnCount: Integer;
        IsInitialized: Boolean;
        ErrGSTSetupMissing: Label 'GST Tax Type is not configured in GST Setup.';
        ErrRateSetupMissing: Label 'Rate Setup does not exist with Column ID %1 for Tax Type %2.',
            Comment = '%1 = Column ID, %2 = Tax Type';
        Text001: Label
            'Processing… @1@@@@@@@@@@@@\GST Group: #2###################\HSN Code: #3###################\Processed: #4###\Total: #5###';

    procedure Initialize()
    begin
        if IsInitialized then
            exit;

        if not GSTSetup.Get() then
            Error(ErrGSTSetupMissing);
        GSTSetup.TestField("GST Tax Type");

        GlobalTaxType := GSTSetup."GST Tax Type";
        TaxSetupMatrixMgmt.FillColumnArray(
            GlobalTaxType, AttributeCaption, AttributeValue,
            RangeAttribute, AttributeID, ColumnCount);

        IsInitialized := true;
    end;

    procedure GenerateGSTRatesForHSNList(
        var HSNCode: Record "HSN/SAC";
        ToStateFilter: Text;
        FromStateFilter: Text;
        GenerateDomestic: Boolean;
        GenerateImport: Boolean)
    var
        Window: Dialog;
        TotalCount: Integer;
        Counter: Integer;
    begin
        Initialize();

        TotalCount := HSNCode.Count();
        if TotalCount = 0 then
            exit;

        Counter := 0;
        Window.Open(Text001);

        if HSNCode.FindSet() then
            repeat
                Counter += 1;
                Window.Update(2, HSNCode."GST Group Code");
                Window.Update(3, HSNCode.Code);
                Window.Update(4, Counter);
                Window.Update(5, TotalCount);
                Window.Update(1, Round(Counter / TotalCount * 10000, 1));

                GenerateGSTRates(
                    HSNCode."GST Group Code", HSNCode.Code,
                    HSNCode."GST %", ToStateFilter, FromStateFilter,
                    GenerateDomestic, GenerateImport, Window);

                Commit(); // Persist each HSN independently
            until HSNCode.Next() = 0;

        Window.Close();
    end;

    procedure GenerateGSTRates(
        GSTGroupCodeParam: Code[20];
        HSNCodeParam: Code[20];
        GSTPercentParam: Integer;
        ToStateFilter: Text;
        FromStateFilter: Text;
        GenerateDomestic: Boolean;
        GenerateImport: Boolean;
        var Window: Dialog)
    var
        FromState: Record State;
        ToState: Record State;
        LocalAttributeValue: array[1000] of Text;
        LocalRangeAttribute: array[1000] of Boolean;
        LocalAttributeID: array[1000] of Integer;
        LocalColumnCount: Integer;
        AttributeCaptionL: array[1000] of Text;
        TotalCombinations: Integer;
        RowIndex: Integer;
    begin
        Initialize();

        TaxSetupMatrixMgmt.FillColumnArray(
            GlobalTaxType, AttributeCaptionL, LocalAttributeValue,
            LocalRangeAttribute, LocalAttributeID, LocalColumnCount);

        FromState.Reset();
        if FromStateFilter <> '' then
            FromState.SetFilter(Code, FromStateFilter);

        ToState.Reset();
        if ToStateFilter <> '' then
            ToState.SetFilter(Code, ToStateFilter)
        else
            ToState.SetRange(Code, '');

        TotalCombinations := Maximum(FromState.Count() * ToState.Count(), 1);
        RowIndex := 0;

        // Domestic: From State × To State
        if GenerateDomestic then
            if FromState.FindSet() then
                repeat
                    if ToState.FindSet() then
                        repeat
                            RowIndex += 1;
                            Window.Update(1, Round(RowIndex / TotalCombinations * 10000, 1));
                            CreateDomesticRate(
                                GSTGroupCodeParam, HSNCodeParam, GSTPercentParam,
                                FromState, ToState, LocalRangeAttribute, GlobalTaxType,
                                LocalAttributeID, LocalColumnCount, LocalAttributeValue,
                                Window);
                        until ToState.Next() = 0;
                until FromState.Next() = 0;

        // Import: blank From State → each To State
        if GenerateImport then
            if ToState.FindSet() then
                repeat
                    RowIndex += 1;
                    CreateImportRate(
                        GSTGroupCodeParam, HSNCodeParam, GSTPercentParam,
                        ToState, LocalRangeAttribute, GlobalTaxType,
                        LocalAttributeID, LocalColumnCount, LocalAttributeValue);
                until ToState.Next() = 0;
    end;

    local procedure CreateDomesticRate(
        GSTGroupCodeParam: Code[20];
        HSNCodeParam: Code[20];
        GSTPercentParam: Integer;
        FromState: Record State;
        ToState: Record State;
        var LocalRangeAttribute: array[1000] of Boolean;
        TaxType: Code[20];
        var LocalAttributeID: array[1000] of Integer;
        LocalColumnCount: Integer;
        var LocalAttributeValue: array[1000] of Text;
        var Window: Dialog)
    var
        GSTRateDecimal: Decimal; // FIX: Use Decimal not Integer for split
    begin
        GSTRateDecimal := GSTPercentParam;

        LocalAttributeValue[1] := GSTGroupCodeParam;
        LocalAttributeValue[2] := HSNCodeParam;
        LocalAttributeValue[3] := FromState.Code;
        LocalAttributeValue[4] := ToState.Code;
        LocalAttributeValue[5] := Format(GSTSetup."GST Effective Date"); // FIX: No hardcode
        LocalAttributeValue[6] := '';

        if FromState.Code = ToState.Code then begin
            // Intra-state: split equally
            LocalAttributeValue[7] := Format(GSTRateDecimal / 2);
            LocalAttributeValue[8] := Format(GSTRateDecimal / 2);
            LocalAttributeValue[9] := '0';
        end else begin
            // Inter-state: full IGST
            LocalAttributeValue[7] := '0';
            LocalAttributeValue[8] := '0';
            LocalAttributeValue[9] := Format(GSTRateDecimal);
        end;

        LocalAttributeValue[10] := '0';
        LocalAttributeValue[11] := 'NO';
        LocalAttributeValue[12] := 'NO';

        InsertAndUpdateTaxRate(
            TaxType, LocalAttributeValue, LocalRangeAttribute,
            LocalAttributeID, LocalColumnCount);

        Window.Update(2, GSTGroupCodeParam);
        Window.Update(3, HSNCodeParam);
    end;

    local procedure CreateImportRate(
        GSTGroupCodeParam: Code[20];
        HSNCodeParam: Code[20];
        GSTPercentParam: Integer;
        ToState: Record State;
        var LocalRangeAttribute: array[1000] of Boolean;
        TaxType: Code[20];
        var LocalAttributeID: array[1000] of Integer;
        LocalColumnCount: Integer;
        var LocalAttributeValue: array[1000] of Text)
    var
        GSTRateDecimal: Decimal;
    begin
        GSTRateDecimal := GSTPercentParam;

        LocalAttributeValue[1] := GSTGroupCodeParam;
        LocalAttributeValue[2] := HSNCodeParam;
        LocalAttributeValue[3] := '';
        LocalAttributeValue[4] := ToState.Code;
        LocalAttributeValue[5] := Format(GSTSetup."GST Effective Date"); // FIX: No hardcode
        LocalAttributeValue[6] := '';
        LocalAttributeValue[7] := '0';
        LocalAttributeValue[8] := '0';
        LocalAttributeValue[9] := Format(GSTRateDecimal);
        LocalAttributeValue[10] := '0';
        LocalAttributeValue[11] := 'NO';
        LocalAttributeValue[12] := 'NO';

        InsertAndUpdateTaxRate(
            TaxType, LocalAttributeValue, LocalRangeAttribute,
            LocalAttributeID, LocalColumnCount);
    end;

    local procedure InsertAndUpdateTaxRate(
        TaxType: Code[20];
        var LocalAttributeValue: array[1000] of Text;
        var LocalRangeAttribute: array[1000] of Boolean;
        var LocalAttributeID: array[1000] of Integer;
        LocalColumnCount: Integer)
    var
        TaxRate: Record "Tax Rate";
        TaxRateValue: Record "Tax Rate Value";
        ColIndex: Integer;
    begin
        // Insert header
        TaxRate.Init();
        TaxRate.ID := CreateGuid();
        TaxRate."Tax Type" := TaxType;
        TaxRate.Insert(true);

        // FIX: Always reset before filtering
        TaxRateValue.Reset();
        TaxRateValue.SetRange("Config ID", TaxRate.ID);
        if TaxRateValue.IsEmpty() then
            TaxSetupMatrixMgmt.InitializeRateValue(TaxRate, TaxType);

        // Update each column
        ColIndex := 1;
        while ColIndex <= LocalColumnCount do begin
            UpdateTaxConfigurationValue(
                TaxRate.ID, TaxType,
                LocalAttributeID, ColIndex,
                LocalAttributeValue, LocalRangeAttribute);
            ColIndex += 1;
        end;

        // Stamp IDs
        UpdateTaxRateId(TaxType, TaxRate.ID);
    end;

    local procedure UpdateTaxConfigurationValue(
        ConfigId: Guid;
        TaxType: Code[20];
        var LocalAttributeID: array[1000] of Integer;
        Index: Integer;
        var LocalAttributeValue: array[1000] of Text;
        var LocalRangeAttribute: array[1000] of Boolean)
    var
        TaxRateSetup: Record "Tax Rate Column Setup";
        TaxRateValue: Record "Tax Rate Value";
        DateValue: Date;
        XmlValue: Text;
    begin
        TaxRateSetup.SetRange("Tax Type", TaxType);
        TaxRateSetup.SetRange("Column ID", LocalAttributeID[Index]);
        if not TaxRateSetup.FindFirst() then
            Error(ErrRateSetupMissing, LocalAttributeID[Index], TaxType);

        TaxSetupMatrixMgmt.ValidateColumnValue(TaxRateSetup, LocalAttributeValue[Index]);

        TaxRateValue.SetRange("Tax Type", TaxType);
        TaxRateValue.SetRange("Config ID", ConfigId);
        TaxRateValue.SetRange("Column ID", LocalAttributeID[Index]);
        TaxRateValue.FindFirst();

        // FIX: Check column type, not hardcoded index
        if TaxRateSetup.Type = TaxRateSetup.Type::Date then begin
            Evaluate(DateValue, LocalAttributeValue[Index]);
            XmlValue := Format(DateValue, 0, 9);
        end else
            XmlValue := LocalAttributeValue[Index];

        TaxSetupMatrixMgmt.UpdateAndValidateRateValue(
            TaxRateValue, TaxRateSetup, XmlValue, LocalRangeAttribute[Index]);
        TaxRateValue.Modify();
    end;

    local procedure UpdateTaxRateId(TaxType: Code[20]; ConfigId: Guid)
    var
        TaxRate: Record "Tax Rate";
    begin
        TaxRate.Get(TaxType, ConfigId);
        if not HasDuplicateTaxSetupID(ConfigId, TaxType) then begin
            TaxRate."Tax Setup ID" := TaxSetupMatrixMgmt.GenerateTaxSetupID(ConfigId, TaxType);
            TaxRate."Tax Rate ID" := TaxSetupMatrixMgmt.GenerateTaxRateID(ConfigId, TaxType);
            TaxRate.Modify();
            TaxSetupMatrixMgmt.UpdateRateIDOnRateValue(ConfigId, TaxRate."Tax Rate ID");
        end;
    end;

    local procedure HasDuplicateTaxSetupID(ConfigID: Guid; TaxType: Code[20]): Boolean
    var
        TaxRateValue: Record "Tax Rate Value";
        TaxRateColumnSetup: Record "Tax Rate Column Setup";
        TaxConfiguration: Record "Tax Rate";
        TaxSetupID: Text; // FIX: Use Text not Text[2000]
    begin
        TaxRateValue.SetRange("Tax Type", TaxType);
        TaxRateValue.SetRange("Config ID", ConfigID);
        if TaxRateValue.IsEmpty() then
            exit(false);

        TaxRateColumnSetup.SetCurrentKey(Sequence);
        TaxRateColumnSetup.SetRange("Tax Type", TaxType);
        TaxRateColumnSetup.SetFilter(
            "Column Type", '%1|%2|%3|%4|%5',
            TaxRateColumnSetup."Column Type"::"Tax Attributes",
            TaxRateColumnSetup."Column Type"::Value,
            TaxRateColumnSetup."Column Type"::"Range From",
            TaxRateColumnSetup."Column Type"::"Range From and Range To",
            TaxRateColumnSetup."Column Type"::"Range To");

        if TaxRateColumnSetup.FindSet() then
            repeat
                TaxRateValue.Reset(); // FIX: Always reset inside loop
                TaxRateValue.SetRange("Tax Type", TaxType);
                TaxRateValue.SetRange("Config ID", ConfigID);
                TaxRateValue.SetRange("Column ID", TaxRateColumnSetup."Column ID");
                if TaxRateValue.FindFirst() then
                    TaxSetupID += TaxRateValue.Value + '|';
            until TaxRateColumnSetup.Next() = 0;

        TaxConfiguration.SetRange("Tax Type", TaxType);
        TaxConfiguration.SetFilter(ID, '<>%1', ConfigID);
        TaxConfiguration.SetRange("Tax Setup ID", TaxSetupID);
        exit(not TaxConfiguration.IsEmpty());
    end;

    procedure ExtractGSTPercent(InputString: Text): Integer
    var
        NumericPart: Text;
        CurrentChar: Text[1];
        i: Integer;
        Result: Integer;
    begin
        NumericPart := '';
        for i := 1 to StrLen(InputString) do begin
            CurrentChar := CopyStr(InputString, i, 1);
            if CurrentChar in ['0', '1', '2', '3', '4', '5', '6', '7', '8', '9'] then
                NumericPart += CurrentChar
            else
                if NumericPart <> '' then
                    break;
        end;

        if (NumericPart <> '') and Evaluate(Result, NumericPart) then
            exit(Result);
        exit(0);
    end;

    procedure RefreshAllGSTPercent()
    var
        HSNSAC: Record "HSN/SAC";
    begin
        if HSNSAC.FindSet() then
            repeat
                HSNSAC."GST %" := ExtractGSTPercent(HSNSAC."GST Group Code");
                HSNSAC.Modify();
            until HSNSAC.Next() = 0;
    end;

    procedure CheckGSTRatesForHSNSelection(var HSNSAC: Record "HSN/SAC")
    var
        GSTRateChecker: Codeunit "GST Rate Checker";
        ProgressDialog: Dialog;
        TotalRecords: Integer;
        CurrentRecord: Integer;
        ProcessingMsg: Label 'Checking GST Rates...\HSN Code: #1########\Progress: #2### of #3###';
    begin
        TotalRecords := HSNSAC.Count();
        if TotalRecords = 0 then begin
            Message('No records selected.');
            exit;
        end;

        CurrentRecord := 0;
        ProgressDialog.Open(ProcessingMsg);

        if HSNSAC.FindSet() then
            repeat
                CurrentRecord += 1;
                ProgressDialog.Update(1, HSNSAC.Code);
                ProgressDialog.Update(2, CurrentRecord);
                ProgressDialog.Update(3, TotalRecords);
                GSTRateChecker.CheckGSTRatesForHSN(HSNSAC);
            until HSNSAC.Next() = 0;

        ProgressDialog.Close();
        Message('GST Rate check completed.\Total HSN records processed: %1', TotalRecords);
    end;
}