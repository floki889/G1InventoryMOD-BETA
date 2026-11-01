
// =====================================================================================
//  Improved Inventory - part 1: Sort button + scroll bar
//  (mod F-ImprovedInventory 1.3.6; part 2, item dragging, is ImprovedInventory_ItemDrag.as)
//  A sort button under the item count of the inventory ("All" tab). Pressing it groups the
//  items by the inventory's own categories, in the order of the category tabs:
//    2 Melee, 3 Ranged, 4 Magic, 5 Wearables, 6 Food, 7 Potions, 8 Materials,
//    9 Documents, 10 Miscellaneous, 11 Artefacts.
//  Items on the hotbar (with a hotkey number) come first, in hotbar order 1-9, 0. Worn
//  wearables also show a number square ("0") but are not hotbar items: they stay in Wearables.
//  Inside a category, items of the same family follow each other: first by the tag that put
//  them into the category (e.g. runes before scrolls, one-handed swords before two-handed),
//  then by their full item type, then by name (A-Z), then by value (highest first).
//
//  Scroll bar (v0.4.0): always visible on the right of the item grid, on every tab. Drag the
//  handle (half as tall as the grid), click the rail to jump there, or use the mouse wheel on it.
//  Pictures: Icons/ScrollThumbTop/Body/Bottom.png (handle in 3 pieces so it stays sharp at any
//  length), ScrollTrack.png (rail), ScrollCap.png (diamonds at the rail ends and on the handle).
//
//  Together with the item dragging (part 2):
//   - After sorting, part 1 tells part 2 "take this order over" with a message on the grid's
//     hover event (index FIS_SignalIndex, item = the sort layer). Part 2 keeps that order (per
//     save game). Dragging afterwards changes it as usual; pressing Sort again re-groups it.
//   - Part 2 is the one that remembers the order; part 1 never re-sorts by itself, so the two
//     never fight. (The stand-alone "keep sorted" mode below is not used in this combined mod.)
//
//  Facts this relies on (read from the game files):
//   - UInventoryMain.TileView_Items = item grid (UDiscreteItemViewWidget), list items are
//     UInventorySlotData (m_Name, m_Value, m_IsEmpty ...). SetListItemsBP sets the order.
//   - UInventoryMain.GenericFilter (UAlkFilterWidget).GetSelectedFilterTag() = active tab.
//   - The player's UInventoryComponent.GetItems() gives the UItemDefinitions (m_Name,
//     MatchesItemType, HasItemSpec). The category tags are those of Script/UI/InventoryFilters.as.
// =====================================================================================


/** Remembered between sessions (only used when the drag mod is not running). */
class UFIS_Settings : USaveGame
{
	UPROPERTY()
	bool bAutoSort = false;

	/** Chosen sort mode (FIS_ModeCategories / FIS_ModeValues / FIS_ModeStack). */
	UPROPERTY()
	int SortMode = 0;
}

const FString FIS_SaveSlot = "FlokiInventorySorting_Settings";

// Sort modes (Sort-by menu). Each one is its own function, see FIS_SortItems().
const int FIS_ModeCategories = 0;
const int FIS_ModeValues = 1;
const int FIS_ModeStack = 2;     // menu entry 3 "Stack all items": an on/off switch per save (part 3), not a sort mode

// Groups of the Values sort, in this order on the grid.
const int FIS_GroupWeapon = 0;
const int FIS_GroupArmor = 1;
const int FIS_GroupRing = 2;
const int FIS_GroupAmulet = 3;
const int FIS_GroupHealDrink = 4;        // healing drinks: instant ones first, then per second
const int FIS_GroupHealDrinkSlow = 5;
const int FIS_GroupManaDrink = 6;        // mana drinks: instant first, then per second
const int FIS_GroupManaDrinkSlow = 7;
const int FIS_GroupStatPotion = 8;       // permanent potions (max HP / mana, strength, dexterity)
const int FIS_GroupFoodHeal = 9;         // food
const int FIS_GroupFoodMana = 10;
const int FIS_GroupHerbHeal = 11;        // herbs and drugs
const int FIS_GroupHerbMana = 12;
const int FIS_GroupRest = 100;   // everything else: sorted like Categories

/** Hover-event index that means "a sort happened, take the grid's order over" (read by the drag mod). */
const int FIS_SignalIndex = -4242;


// -------------------------------------------------------------------------------------
//  Attaches the sort layer to the inventory screen.
// -------------------------------------------------------------------------------------
class UFIS_InventoryExtension : UGothicModExt_WidgetExtension
{
	default AddToWidgetOfClass = n"/Game/UI/ManagementUI/Inventory/W_Inventory_Main.W_Inventory_Main_C";

	UFIS_Layer FIS_Layer;

	UFUNCTION(BlueprintOverride)
	void Initialize()
	{
		FIS_TryInstall();
		System::SetTimer(this, n"FIS_OnTimer", 0.5f, true);
	}

	UFUNCTION(BlueprintOverride)
	void Tick(FGeometry MyGeometry, float InDeltaTime)
	{
		FIS_TryInstall();
	}

	UFUNCTION()
	private void FIS_OnTimer()
	{
		FIS_TryInstall();
	}

	void FIS_TryInstall()
	{
		if (IsValid(FIS_Layer))
			return;

		UUserWidget Base = GetWidget();
		if (!IsValid(Base))
			return;

		// Wait until the screen has been drawn once.
		FVector2D BaseSize = Base.GetCachedGeometry().GetAbsoluteSize();
		if (BaseSize.X < 10.0 || BaseSize.Y < 10.0)
			return;

		// Our things go into a canvas ABOVE the inventory (like InventoryItemDrag): putting them
		// inside the inventory's overlay made it grow and pushed the item grid aside.
		UPanelWidget Host = FIS_FindCanvasAbove(Base);
		if (!IsValid(Host))
			Host = FIS_FindCanvasInside(Base);
		if (!IsValid(Host))
			return;

		UCanvasPanel OwnCanvas = Cast<UCanvasPanel>(Base.ConstructWidget(UCanvasPanel, n"FIS_Canvas"));
		if (!IsValid(OwnCanvas))
			return;
		FIS_AddFullSize(Host, OwnCanvas, 900);
		OwnCanvas.SetVisibility(ESlateVisibility::SelfHitTestInvisible);

		UFIS_Layer Layer = Cast<UFIS_Layer>(Base.ConstructWidget(UFIS_Layer, n"FIS_Layer"));
		if (!IsValid(Layer))
			return;
		FIS_AddFullSize(OwnCanvas, Layer, 0);
		Layer.FIS_HostInfo = f"{Host.GetName().ToString()} ({Host.GetClass().GetName().ToString()})";
		Layer.FIS_Setup(Base, OwnCanvas);
		FIS_Layer = Layer;

		// An empty widget INSIDE the inventory: it only ticks while the inventory is drawn, which
		// tells the layer when to show the button (size 0, so it never changes the layout).
		UPanelWidget Inner = FIS_FindPanelInside(Base);
		if (IsValid(Inner))
		{
			UFIS_Heartbeat Beat = Cast<UFIS_Heartbeat>(Base.ConstructWidget(UFIS_Heartbeat, n"FIS_Heartbeat"));
			if (IsValid(Beat))
			{
				Beat.FIS_Layer = Layer;
				FIS_AddFullSize(Inner, Beat, 0);
				Beat.SetVisibility(ESlateVisibility::HitTestInvisible);
			}
		}
	}
}


// -------------------------------------------------------------------------------------
//  Empty widget inside the inventory: reports "the inventory is on screen" every frame.
// -------------------------------------------------------------------------------------
class UFIS_Heartbeat : UUserWidget
{
	UFIS_Layer FIS_Layer;

	UFUNCTION(BlueprintOverride)
	void Tick(FGeometry MyGeometry, float InDeltaTime)
	{
		if (IsValid(FIS_Layer))
			FIS_Layer.FIS_LastBeat = FDateTime::Now().GetTicks();
	}
}


// -------------------------------------------------------------------------------------
//  Invisible click area on top of the sort picture.
// -------------------------------------------------------------------------------------
class UFIS_ClickArea : UUserWidget
{
	UFIS_Layer FIS_Layer;
	bool FIS_bDown = false;

	UFUNCTION(BlueprintOverride)
	FEventReply OnMouseButtonDown(FGeometry MyGeometry, FPointerEvent MouseEvent)
	{
		if (!IsValid(FIS_Layer))
			return Widget::Unhandled();
		if (MouseEvent.GetEffectingButton() == EKeys::LeftMouseButton)
		{
			FIS_bDown = true;
			return Widget::Handled();
		}
		if (MouseEvent.GetEffectingButton() == EKeys::RightMouseButton)
		{
			FIS_Layer.FIS_OnRightClick();
			return Widget::Handled();
		}
		return Widget::Unhandled();
	}

	// A fast second click arrives as a double click: treat it as a normal press.
	UFUNCTION(BlueprintOverride)
	FEventReply OnMouseButtonDoubleClick(FGeometry InMyGeometry, FPointerEvent InMouseEvent)
	{
		if (InMouseEvent.GetEffectingButton() == EKeys::LeftMouseButton)
		{
			FIS_bDown = true;
			return Widget::Handled();
		}
		return Widget::Unhandled();
	}

	UFUNCTION(BlueprintOverride)
	FEventReply OnMouseButtonUp(FGeometry MyGeometry, FPointerEvent MouseEvent)
	{
		if (!IsValid(FIS_Layer))
			return Widget::Unhandled();
		if (MouseEvent.GetEffectingButton() == EKeys::LeftMouseButton && FIS_bDown)
		{
			FIS_bDown = false;
			FIS_Layer.FIS_OnClick();
			return Widget::Handled();
		}
		return Widget::Handled();
	}
}


// -------------------------------------------------------------------------------------
//  Invisible full-screen layer while the Sort-by menu is open: a click outside the menu
//  closes it (that click does nothing else).
// -------------------------------------------------------------------------------------
class UFIS_OutsideCatcher : UUserWidget
{
	UFIS_Layer FIS_Layer;

	UFUNCTION(BlueprintOverride)
	FEventReply OnMouseButtonDown(FGeometry MyGeometry, FPointerEvent MouseEvent)
	{
		if (IsValid(FIS_Layer))
			FIS_Layer.FIS_CloseMenu();
		return Widget::Handled();
	}

	UFUNCTION(BlueprintOverride)
	FEventReply OnMouseButtonDoubleClick(FGeometry InMyGeometry, FPointerEvent InMouseEvent)
	{
		if (IsValid(FIS_Layer))
			FIS_Layer.FIS_CloseMenu();
		return Widget::Handled();
	}
}


// -------------------------------------------------------------------------------------
//  Invisible area over one line of the Sort-by menu (an entry, or the Apply button = -1).
// -------------------------------------------------------------------------------------
class UFIS_MenuItemArea : UUserWidget
{
	UFIS_Layer FIS_Layer;
	int FIS_Index = 0;

	UFUNCTION(BlueprintOverride)
	FEventReply OnMouseButtonDown(FGeometry MyGeometry, FPointerEvent MouseEvent)
	{
		if (IsValid(FIS_Layer) && MouseEvent.GetEffectingButton() == EKeys::LeftMouseButton)
			FIS_Layer.FIS_OnMenuItem(FIS_Index);
		return Widget::Handled();
	}

	UFUNCTION(BlueprintOverride)
	FEventReply OnMouseButtonDoubleClick(FGeometry InMyGeometry, FPointerEvent InMouseEvent)
	{
		if (IsValid(FIS_Layer) && InMouseEvent.GetEffectingButton() == EKeys::LeftMouseButton)
			FIS_Layer.FIS_OnMenuItem(FIS_Index);
		return Widget::Handled();
	}
}


// -------------------------------------------------------------------------------------
//  Invisible area over the scroll bar: drag, click and mouse wheel.
// -------------------------------------------------------------------------------------
class UFIS_ScrollArea : UUserWidget
{
	UFIS_Layer FIS_Layer;

	UFUNCTION(BlueprintOverride)
	FEventReply OnMouseButtonDown(FGeometry MyGeometry, FPointerEvent MouseEvent)
	{
		if (!IsValid(FIS_Layer) || !(MouseEvent.GetEffectingButton() == EKeys::LeftMouseButton))
			return Widget::Handled();
		FIS_Layer.FIS_BarPress(MouseEvent.GetScreenSpacePosition());
		FEventReply Reply = Widget::Handled();
		return Widget::CaptureMouse(Reply, this);
	}

	UFUNCTION(BlueprintOverride)
	FEventReply OnMouseButtonDoubleClick(FGeometry InMyGeometry, FPointerEvent InMouseEvent)
	{
		if (!IsValid(FIS_Layer) || !(InMouseEvent.GetEffectingButton() == EKeys::LeftMouseButton))
			return Widget::Handled();
		FIS_Layer.FIS_BarPress(InMouseEvent.GetScreenSpacePosition());
		FEventReply Reply = Widget::Handled();
		return Widget::CaptureMouse(Reply, this);
	}

	UFUNCTION(BlueprintOverride)
	FEventReply OnMouseMove(FGeometry MyGeometry, FPointerEvent MouseEvent)
	{
		if (!IsValid(FIS_Layer) || !FIS_Layer.FIS_bBarDragging)
			return Widget::Unhandled();
		FIS_Layer.FIS_BarDrag(MouseEvent.GetScreenSpacePosition());
		return Widget::Handled();
	}

	UFUNCTION(BlueprintOverride)
	FEventReply OnMouseButtonUp(FGeometry MyGeometry, FPointerEvent MouseEvent)
	{
		if (!IsValid(FIS_Layer) || !FIS_Layer.FIS_bBarDragging)
			return Widget::Handled();
		FIS_Layer.FIS_bBarDragging = false;
		FEventReply Reply = Widget::Handled();
		return Widget::ReleaseMouseCapture(Reply);
	}

	UFUNCTION(BlueprintOverride)
	void OnMouseCaptureLost()
	{
		if (IsValid(FIS_Layer))
			FIS_Layer.FIS_bBarDragging = false;
	}

	UFUNCTION(BlueprintOverride)
	FEventReply OnMouseWheel(FGeometry MyGeometry, FPointerEvent MouseEvent)
	{
		if (IsValid(FIS_Layer))
			FIS_Layer.FIS_BarWheel(MouseEvent.GetWheelDelta());
		return Widget::Handled();
	}
}


// -------------------------------------------------------------------------------------
//  Full-size layer inside the inventory: places the button, sorts, shows debug text.
// -------------------------------------------------------------------------------------
class UFIS_Layer : UUserWidget
{
	// ============================ settings ============================

	// Debug readout in the top-left corner of the inventory. Set to false once everything works.
	bool FIS_Debug = false;

	// Size and place of the button, measured in heights of the item-count number ("261").
	float64 FIS_IconHeight = 1.2;   // picture height
	float64 FIS_Gap = 0.25;         // space between the number and the picture
	float64 FIS_OffsetX = 0.0;      // extra shift right (+) / left (-)
	float64 FIS_OffsetY = 0.0;      // extra shift down (+) / up (-)
	float64 FIS_IconAspect = 1.45;            // width / height of the whole Sort button (frame)
	float64 FIS_SymbolHeight = 0.62;          // arrows picture height, part of the button height
	float64 FIS_SymbolAspect = 451.0 / 320.0; // width / height of SortIcon.png
	// false = the button is only the arrows picture (no frame / background behind it).
	bool FIS_ShowButtonFrame = false;
	// If the inventory's Close button is found, the Sort button gets its height and its level.
	bool FIS_MatchCloseButton = true;
	float64 FIS_CloseHeightScale = 1.0;   // 1.0 = exactly as tall as the Close button (as the game reports it)
	float64 FIS_ButtonScale = 1.15;       // extra size: the Close button is drawn bigger than it reports

	// Scroll bar, measured in tile widths (one item square).
	bool FIS_ShowScrollBar = true;
	float64 FIS_BarOffsetX = 0.17;    // centre of the bar, to the right of the grid's right edge (middle of the gap)
	float64 FIS_BarOffsetY = 0.0;     // shift the whole bar down (+) / up (-)
	float64 FIS_BarTopInset = 0.39;   // rail starts this far below the grid's top edge (= top of the first tiles)
	float64 FIS_BarBottomInset = 0.44; // and ends this far above the grid's bottom edge (= bottom of the last tiles)
	float64 FIS_ThumbWidth = 0.105;   // the handle
	float64 FIS_CapGap = 0.03;        // space between an end diamond and the handle
	float64 FIS_ThumbTipAspect = 44.0 / 32.0;   // height / width of ScrollThumbTop.png
	float64 FIS_GemSize = 0.15;       // diamond in the middle of the handle
	float64 FIS_TrackWidth = 0.045;   // the thin rail
	float64 FIS_CapSize = 0.22;       // diamonds at both ends of the rail
	float64 FIS_HitWidth = 0.45;      // width of the area that reacts to the mouse
	float64 FIS_ThumbLength = 0.45;   // handle length, part of the rail

	// Showing / hiding together with the inventory's open and close animation.
	float64 FIS_OpenDelay = 0.05;     // seconds after the open animation before the bar and button appear
	float64 FIS_AnimIgnoreAfter = 2.0; // an animation playing longer than this is a looping one: ignored
	float64 FIS_FadeInTime = 0.15;    // then they fade in over this time

	// Tooltip when the mouse rests on the Sort button (looks like the game's item tooltips).
	bool FIS_ShowTooltip = true;
	FString FIS_TipTitle = "SORT YOUR ITEMS";
	FString FIS_TipAction = "Click RMB to select type of sorting";
	float64 FIS_TipDelay = 0.0;       // seconds of hovering before it appears (0 = at once)
	// Right-click menu (text only for now, the options do nothing yet).
	TArray<FString> FIS_MenuOptions;
	FString FIS_MenuTitle = "SORT BY:";
	FString FIS_ApplyText = "APPLY";
	// Entries that can be chosen (0/1 = sort mode, 2 = "Stack all items" on/off).
	TArray<bool> FIS_MenuOptionActive;
	// Colour of the menu entries: the game's warm text colour of tooltip stats ("Point Dmg", "60").
	FLinearColor FIS_MenuOptionColor = FLinearColor(0.579, 0.400, 0.330, 1.0);
	// Diamond of "3. Stack all items" while stacking is on in this save: bright gold.
	FLinearColor FIS_StackOnMarkColor = FLinearColor(1.0, 0.62, 0.06, 1.0);
	// Colour of the tooltip hint "Click RMB to select type of sorting": the game's warm text
	// colour, like the menu entries (FIS_MenuOptionColor).
	FLinearColor FIS_TipActionColor = FLinearColor(0.579, 0.400, 0.330, 1.0);
	float64 FIS_TipTitleScale = 1.45; // title font size compared with the item-count font

	// Sound of the Sort button: the game's standard button click (FMOD event).
	FString FIS_ClickSoundPath = "/Game/FMOD/Events/SFX/UI/SFX_UI_Action_Button_Click.SFX_UI_Action_Button_Click";

	// Look of the picture.
	FLinearColor FIS_ColorNormal = FLinearColor(0.80, 0.80, 0.80, 1.0);
	FLinearColor FIS_ColorHover = FLinearColor(1.0, 1.0, 1.0, 1.0);
	float64 FIS_HoverScale = 1.08;
	float64 FIS_PressScale = 0.94;

	// ============================ state ============================

	UUserWidget FIS_Base;
	UCanvasPanel FIS_Canvas;
	FString FIS_HostInfo = "-";
	UTextBlock FIS_DebugText;
	UImage FIS_Icon;                  // the arrows picture (SortIcon.png)
	UImage FIS_BtnFrame;              // button background + frame, from the game's Close button
	FSlateBrush FIS_BtnBrushNormal;
	FSlateBrush FIS_BtnBrushHover;
	FSlateBrush FIS_BtnBrushPressed;
	bool FIS_bBtnStyled = false;
	bool FIS_bBtnFallbackDone = false;
	int FIS_BtnBrushState = -1;       // 0 normal, 1 hover, 2 pressed (last brush set)
	FString FIS_BtnStyleInfo = "-";
	UFIS_OutsideCatcher FIS_Catcher;
	UFIS_ClickArea FIS_Click;
	FString FIS_IconInfo = "-";

	UInventoryMain FIS_Inv;
	UDiscreteItemViewWidget FIS_Grid;
	UAlkFilterWidget FIS_Filter;

	UTextBlock FIS_CountText;
	UWidget FIS_CloseBtn;            // the inventory's Close button (size / level reference)
	TArray<UWidget> FIS_CloseParts;  // every visible part of it (frame, key icon, text)
	int64 FIS_NextCloseSearch = 0;
	FString FIS_CountInfo = "not searched yet";
	int64 FIS_NextCountSearch = 0;

	UImage FIS_Track;
	UImage FIS_Thumb;                 // handle body (stretches)
	UImage FIS_ThumbTip1;             // handle top point
	UImage FIS_ThumbTip2;             // handle bottom point
	UImage FIS_ThumbGem;              // diamond in the middle of the handle
	UImage FIS_CapTop;
	UImage FIS_CapBottom;
	UFIS_ScrollArea FIS_BarArea;
	bool FIS_bBarShown = false;
	bool FIS_bBarDragging = false;
	float64 FIS_BarGrabY = 0.0;       // cursor minus handle top, while dragging (screen px)
	float64 FIS_TrackTop = 0.0;       // screen px
	float64 FIS_TrackLen = 0.0;
	float64 FIS_SlideTop = 0.0;       // the handle moves between the two end diamonds
	float64 FIS_SlideLen = 0.0;
	float64 FIS_ThumbTop = 0.0;
	float64 FIS_ThumbLen = 0.0;
	float64 FIS_DragThumbTop = 0.0;
	FString FIS_BarInfo = "-";

	FVector2D FIS_BtnAbsPos;
	FVector2D FIS_BtnAbsSize;
	bool FIS_bShown = false;
	int64 FIS_LastBeat = 0;
	TArray<UCommonActivatableWidget> FIS_Activatables;   // the inventory and the screens around it
	TArray<bool> FIS_SeenActive;
	TArray<UUserWidget> FIS_ChainWidgets;   // the inventory and every user widget around it (open/close animations)
	TArray<int64> FIS_AnimSince;            // when each one started animating (0 = not animating)
	FString FIS_AnimInfo = "-";
	int64 FIS_ShownSince = 0;       // when the inventory became active (0 = not shown)
	FString FIS_ActiveInfo = "-";         // last frame the inventory was drawn (set by UFIS_Heartbeat)
	bool FIS_bHover = false;

	bool FIS_bDragMod = true;       // combined mod: the item dragging part is always there
	int64 FIS_NextDragModSearch = 0;

	// Category tags (parallel arrays, in category order).
	TArray<FGameplayTag> FIS_Tags;
	TArray<int> FIS_TagCats;
	TArray<FString> FIS_CatNames;
	int FIS_WearablesCat = 3;           // index of "Wearables" in FIS_CatNames
	TMap<FString, int> FIS_CatByName;     // item name -> category (0 = Melee ... 9 = Artefacts)
	TMap<FString, int> FIS_SubByName;     // item name -> which category tag matched (runes before scrolls ...)
	TMap<FString, FString> FIS_TypeByName; // item name -> full item type tag (same family = same text start)
	TMap<FString, UItemDefinition> FIS_DefByName;  // item name (+ "|value") -> its definition (stats)
	FString FIS_ValuesInfo = "-";
	FString FIS_InvInfo = "-";

	UFIS_Settings FIS_Settings;
	TArray<UObject> FIS_LastApplied;
	bool FIS_AutoBlocked = false;
	TArray<int64> FIS_AutoTimes;

	int FIS_Sorts = 0;
	UCanvasPanel FIS_Tip;
	UImage FIS_TipBg;
	UImage FIS_TipOutline;
	bool FIS_bTipGameStyle = false;   // brushes copied from the game's own item tooltip
	bool FIS_bTipFallbackDone = false;
	float64 FIS_TipLineH = 1.5;
	UImage FIS_TipLine;
	UImage FIS_TipMouse;
	UTextBlock FIS_TipTitleText;
	UTextBlock FIS_TipActionText;
	bool FIS_bTipFonts = false;
	bool FIS_bTipShown = false;
	int64 FIS_HoverSince = 0;
	FVector2D FIS_TipSize;
	FVector2D FIS_TipPos;            // top-left of the tooltip on our canvas
	TArray<UTextBlock> FIS_TipOptionTexts;
	TArray<UImage> FIS_TipOptionMarks;          // diamond in front of the chosen entry
	TArray<UFIS_MenuItemArea> FIS_TipOptionAreas;
	TArray<float64> FIS_TipOptionTops;          // position of each entry line in the panel
	float64 FIS_TipOptionH = 0.0;
	UImage FIS_TipApplyFrame;
	UTextBlock FIS_TipApplyText;
	UFIS_MenuItemArea FIS_TipApplyArea;
	FVector2D FIS_TipApplyPos;
	FVector2D FIS_TipApplySize;
	int FIS_PendingMode = 0;                    // chosen in the menu, saved with Apply
	bool FIS_PendingStack = false;              // "Stack all items" ticked in the menu, saved with Apply
	UFIST_Stacker FIS_Stacker;                  // part 3: merges identical items on the grid
	bool FIS_bMenuOpen = false;
	bool FIS_bTipDirty = false;
	UFMODEvent FIS_ClickSound;
	bool FIS_bClickSoundTried = false;
	int FIS_KeepScrollOffset = 0;
	int FIS_KeepScrollFrames = 0;
	int FIS_LastUnmatched = 0;
	int FIS_LastFullMatches = 0;
	FString FIS_LastHotbar = "";    // hotbar items found in the last sort    // items found by "name|value" (the rest by name only)
	int FIS_SharedNames = 0;        // item names used by different kinds of items (rune + scroll ...)
	FString FIS_UnmatchedNames = "";
	FString FIS_LastAction = "-";

	// ------------------------------------------------------------------
	//  Setup
	// ------------------------------------------------------------------

	void FIS_Setup(UUserWidget Base, UCanvasPanel Canvas)
	{
		FIS_Base = Base;
		FIS_Canvas = Canvas;
		Canvas.SetRenderOpacity(1.0);
		SetVisibility(ESlateVisibility::HitTestInvisible);
		FIS_LoadSettings();
		FIS_SetupCategories();
		FIS_CollectActivatables();

		// The picture.
		// Button background + frame (filled in by FIS_ApplyButtonStyle from the Close button).
		FIS_BtnFrame = Cast<UImage>(Base.ConstructWidget(UImage, n"FIS_BtnFrame"));
		if (IsValid(FIS_BtnFrame))
		{
			FIS_AddSmall(Canvas, FIS_BtnFrame, 9);
			FIS_BtnFrame.SetVisibility(ESlateVisibility::Collapsed);
		}

		// Full-screen click catcher while the Sort-by menu is open (under the button and the menu).
		FIS_Catcher = Cast<UFIS_OutsideCatcher>(Base.ConstructWidget(UFIS_OutsideCatcher, n"FIS_Catcher"));
		if (IsValid(FIS_Catcher))
		{
			FIS_Catcher.FIS_Layer = this;
			FIS_AddFullSize(Canvas, FIS_Catcher, 8);
			FIS_Catcher.SetVisibility(ESlateVisibility::Collapsed);
		}

		FIS_Icon = Cast<UImage>(Base.ConstructWidget(UImage, n"FIS_Icon"));
		if (IsValid(FIS_Icon))
		{
			FIS_AddSmall(Canvas, FIS_Icon, 10);
			FIS_Icon.SetVisibility(ESlateVisibility::Collapsed);
			UTexture2D Tex = FIS_LoadIcon();
			if (IsValid(Tex))
				FIS_Icon.SetBrushFromTexture(Tex, false);
			FIS_Icon.SetColorAndOpacity(FIS_ColorNormal);
		}

		// The tooltip of the Sort button.
		if (FIS_ShowTooltip)
			FIS_MakeTooltip(Base, Canvas);

		// The scroll bar (rail, end diamonds, handle, mouse area).
		if (FIS_ShowScrollBar)
		{
			FIS_Track = FIS_MakeImage(Base, Canvas, n"FIS_Track", "ScrollTrack.png", 5);
			FIS_CapTop = FIS_MakeImage(Base, Canvas, n"FIS_CapTop", "ScrollCap.png", 6);
			FIS_CapBottom = FIS_MakeImage(Base, Canvas, n"FIS_CapBottom", "ScrollCap.png", 6);
			FIS_Thumb = FIS_MakeImage(Base, Canvas, n"FIS_Thumb", "ScrollThumbBody.png", 7);
			FIS_ThumbTip1 = FIS_MakeImage(Base, Canvas, n"FIS_ThumbTip1", "ScrollThumbTop.png", 7);
			FIS_ThumbTip2 = FIS_MakeImage(Base, Canvas, n"FIS_ThumbTip2", "ScrollThumbBottom.png", 7);
			FIS_ThumbGem = FIS_MakeImage(Base, Canvas, n"FIS_ThumbGem", "ScrollCap.png", 8);
			FIS_BarArea = Cast<UFIS_ScrollArea>(Base.ConstructWidget(UFIS_ScrollArea, n"FIS_BarArea"));
			if (IsValid(FIS_BarArea))
			{
				FIS_BarArea.FIS_Layer = this;
				FIS_AddSmall(Canvas, FIS_BarArea, 8);
				FIS_BarArea.SetVisibility(ESlateVisibility::Collapsed);
			}
		}

		// The click area over it.
		FIS_Click = Cast<UFIS_ClickArea>(Base.ConstructWidget(UFIS_ClickArea, n"FIS_Click"));
		if (IsValid(FIS_Click))
		{
			FIS_Click.FIS_Layer = this;
			FIS_AddSmall(Canvas, FIS_Click, 11);
			FIS_Click.SetVisibility(ESlateVisibility::Collapsed);
		}

		if (FIS_Debug)
		{
			FIS_DebugText = Cast<UTextBlock>(Base.ConstructWidget(UTextBlock, n"FIS_DebugText"));
			if (IsValid(FIS_DebugText))
			{
				// Top-right corner of the screen, fixed size.
				UCanvasPanelSlot TextSlot = Canvas.AddChildToCanvas(FIS_DebugText);
				if (IsValid(TextSlot))
				{
					FAnchors TopRight;
					TopRight.Minimum = FVector2D(1.0, 0.0);
					TopRight.Maximum = FVector2D(1.0, 0.0);
					TextSlot.SetAnchors(TopRight);
					TextSlot.SetAlignment(FVector2D(1.0, 0.0));
					TextSlot.SetAutoSize(false);
					TextSlot.SetSize(FVector2D(1200.0, 900.0));
					TextSlot.SetPosition(FVector2D(-30.0, 60.0));
					TextSlot.SetZOrder(12);
				}
				FIS_DebugText.SetVisibility(ESlateVisibility::HitTestInvisible);
				FIS_DebugText.SetRenderTransformPivot(FVector2D(1.0, 0.0));
				FIS_DebugText.SetRenderScale(FVector2D(0.55, 0.55));
			}
		}
		FIS_LastAction = "installed";
	}

	/** A picture from the mod's Icons folder (nullptr if missing). */
	UTexture2D FIS_LoadTexture(FString FileName)
	{
		FString TexPath = Paths::ProjectModsDir() + "F-ImprovedInventory/Icons/" + FileName;
		if (!Paths::FileExists(TexPath))
			TexPath = Paths::ProjectDir() + "Mods/F-ImprovedInventory/Icons/" + FileName;
		if (!Paths::FileExists(TexPath))
			return nullptr;
		return Rendering::ImportFileAsTexture2D(TexPath);
	}

	UImage FIS_MakeImage(UUserWidget Base, UCanvasPanel Canvas, FName WidgetName, FString FileName, int ZOrder)
	{
		UImage Img = Cast<UImage>(Base.ConstructWidget(UImage, WidgetName));
		if (!IsValid(Img))
			return nullptr;
		FIS_AddSmall(Canvas, Img, ZOrder);
		UTexture2D Tex = FIS_LoadTexture(FileName);
		if (IsValid(Tex))
			Img.SetBrushFromTexture(Tex, false);
		else
			FIS_BarInfo = f"{FileName} NOT found";
		Img.SetVisibility(ESlateVisibility::Collapsed);
		return Img;
	}

	UTexture2D FIS_LoadIcon()
	{
		FString IconPath = Paths::ProjectModsDir() + "F-ImprovedInventory/Icons/SortIcon.png";
		if (!Paths::FileExists(IconPath))
			IconPath = Paths::ProjectDir() + "Mods/F-ImprovedInventory/Icons/SortIcon.png";
		if (!Paths::FileExists(IconPath))
		{
			FIS_IconInfo = "SortIcon.png NOT found";
			return nullptr;
		}
		UTexture2D Tex = Rendering::ImportFileAsTexture2D(IconPath);
		FIS_IconInfo = IsValid(Tex) ? f"loaded {IconPath}" : f"could not load {IconPath}";
		return Tex;
	}

	/** The category tags, same as the game's filter tabs (Script/UI/InventoryFilters.as). */
	void FIS_SetupCategories()
	{
		FIS_Tags.Empty();
		FIS_TagCats.Empty();
		FIS_CatNames.Empty();

		FIS_CatNames.Add("Melee");          // tab 2
		FIS_AddTag(0, GameplayTag::Item_Weapon_Sword_OneHand);
		FIS_AddTag(0, GameplayTag::Item_Weapon_Sword_TwoHand);
		FIS_AddTag(0, GameplayTag::Item_Weapon_Mace_OneHand);
		FIS_AddTag(0, GameplayTag::Item_Weapon_Orc_TwoHand);
		FIS_AddTag(0, GameplayTag::Item_Weapon_Axe_OneHand);
		FIS_AddTag(0, GameplayTag::Item_Weapon_Axe_TwoHand);
		FIS_AddTag(0, GameplayTag::Item_Weapon_Staff_TwoHand);
		FIS_AddTag(0, GameplayTag::Item_Weapon_Fist);

		FIS_CatNames.Add("Ranged");         // tab 3
		FIS_AddTag(1, GameplayTag::Item_Weapon_Bow);
		FIS_AddTag(1, GameplayTag::Item_Weapon_Crossbow);
		FIS_AddTag(1, GameplayTag::Item_Ammo);
		FIS_AddTag(1, GameplayTag::Item_Projectile_Arrow);
		FIS_AddTag(1, GameplayTag::Item_Projectile_Bolt);

		FIS_CatNames.Add("Magic");          // tab 4
		FIS_AddTag(2, GameplayTag::Item_Weapon_Rune);
		FIS_AddTag(2, GameplayTag::Item_Weapon_Scroll);

		FIS_CatNames.Add("Wearables");      // tab 5
		FIS_AddTag(3, GameplayTag::Item_Armor);
		FIS_AddTag(3, GameplayTag::Item_Ring);
		FIS_AddTag(3, GameplayTag::Item_Amulet);

		FIS_CatNames.Add("Food");           // tab 6
		FIS_AddTag(4, GameplayTag::Item_Food);
		FIS_AddTag(4, GameplayTag::Item_Herb);
		FIS_AddTag(4, GameplayTag::Item_Drug);

		FIS_CatNames.Add("Potions");        // tab 7
		FIS_AddTag(5, GameplayTag::Item_Potion);

		FIS_CatNames.Add("Materials");      // tab 8
		FIS_AddTag(6, GameplayTag::Item_Ore);
		FIS_AddTag(6, GameplayTag::Item_Material);
		FIS_AddTag(6, GameplayTag::Item_Trophy);
		FIS_AddTag(6, GameplayTag::Item_Property_Forge);
		FIS_AddTag(6, GameplayTag::Item_Recipe);

		FIS_CatNames.Add("Documents");      // tab 9
		FIS_AddTag(7, GameplayTag::Item_Writing);

		FIS_CatNames.Add("Miscellaneous");  // tab 10
		FIS_AddTag(8, GameplayTag::Item_Junk);
		FIS_AddTag(8, GameplayTag::Item_Instrument);
		FIS_AddTag(8, GameplayTag::Item_Lockpick);
		FIS_AddTag(8, GameplayTag::Item_Weapon_Torch);

		FIS_CatNames.Add("Artefacts");      // tab 11
		FIS_AddTag(9, GameplayTag::Item_Quest);
		FIS_AddTag(9, GameplayTag::Item_Key);
	}

	void FIS_AddTag(int Cat, FGameplayTag Tag)
	{
		FIS_Tags.Add(Tag);
		FIS_TagCats.Add(Cat);
	}

	// ------------------------------------------------------------------
	//  Every frame while the inventory is shown
	// ------------------------------------------------------------------

	UFUNCTION(BlueprintOverride)
	void Tick(FGeometry MyGeometry, float InDeltaTime)
	{
		int64 NowTicks = FDateTime::Now().GetTicks();
		FIS_FindParts();
		FIS_FindDragMod(NowTicks);

		// The inventory is open while it is drawn (heartbeat) AND it and its screens are active.
		// Closing deactivates them at once (before the close animation), so we hide at once.
		bool bAnimating = FIS_Animating(NowTicks);
		bool bOpen = NowTicks - FIS_LastBeat < 1000000 && FIS_AllActive() && !bAnimating;
		if (!bOpen)
			FIS_ShownSince = 0;
		else if (FIS_ShownSince == 0)
			FIS_ShownSince = NowTicks;

		// After opening: wait for the open animation, then fade in.
		float64 Alpha = 0.0;
		if (bOpen)
		{
			float64 Secs = float64(NowTicks - FIS_ShownSince) / 10000000.0;
			Alpha = FIS_FadeInTime > 0.0 ? (Secs - FIS_OpenDelay) / FIS_FadeInTime : (Secs >= FIS_OpenDelay ? 1.0 : 0.0);
			Alpha = Math::Clamp(Alpha, 0.0, 1.0);
		}
		bool bScreenShown = Alpha > 0.0;
		FIS_SetPartsOpacity(Alpha);

		bool bAllTab = bScreenShown && FIS_IsAllTab();
		if (IsValid(FIS_DebugText))
		{
			// The debug text stays while the inventory is drawn, also during its animations.
			bool bDrawn = NowTicks - FIS_LastBeat < 1000000;
			ESlateVisibility DebugVis = bDrawn ? ESlateVisibility::HitTestInvisible : ESlateVisibility::Collapsed;
			if (FIS_DebugText.GetVisibility() != DebugVis)
				FIS_DebugText.SetVisibility(DebugVis);
		}

		// The item-count number the button sits under.
		if (IsValid(FIS_CountText) && !FIS_CountText.IsVisible())
			FIS_CountText = nullptr;
		if (!IsValid(FIS_CountText) && IsValid(FIS_Grid) && NowTicks >= FIS_NextCountSearch)
		{
			FIS_NextCountSearch = NowTicks + 5000000;   // try again in 0.5 s
			FIS_CountText = FIS_FindCountText();
		}
		if (FIS_MatchCloseButton && IsValid(FIS_CloseBtn) && !FIS_CloseBtn.IsVisible())
			FIS_CloseBtn = nullptr;
		if (FIS_MatchCloseButton && !IsValid(FIS_CloseBtn) && IsValid(FIS_Grid) && NowTicks >= FIS_NextCloseSearch)
		{
			FIS_NextCloseSearch = NowTicks + 5000000;
			FIS_CloseBtn = FIS_FindCloseButton();
		}

		FVector2D Mouse = WidgetLayout::GetMousePositionOnPlatform();
		FIS_PlaceButton(bAllTab && IsValid(FIS_CountText), Mouse);
		FIS_UpdateTooltip(NowTicks, Mouse);

		// For a few frames after sorting, hold the grid at the row it was on.
		if (FIS_KeepScrollFrames > 0 && IsValid(FIS_Grid))
		{
			FIS_KeepScrollFrames--;
			if (!FIS_bBarDragging && FIS_Grid.GetCurrentScrollOffset() != FIS_KeepScrollOffset)
				FIS_Grid.SetScrollOffset(FIS_KeepScrollOffset);
		}

		FIS_UpdateScrollBar(bScreenShown && IsValid(FIS_Grid), Mouse);

		// Part 3: "Stack all items" (identical items shown once with their total).
		if (IsValid(FIS_Grid))
		{
			if (!IsValid(FIS_Stacker))
				FIS_Stacker = Cast<UFIST_Stacker>(NewObject(this, UFIST_Stacker));
			if (IsValid(FIS_Stacker))
				FIS_Stacker.FIST_Update(FIS_Inv, FIS_Grid, NowTicks);
		}

		if (bAllTab)
			FIS_KeepAutoSorted(NowTicks);

		if (FIS_Debug)
			FIS_UpdateDebugText(bAllTab, Mouse);
	}

	/** Fades the button and the scroll bar (not the debug text). */
	void FIS_SetPartsOpacity(float64 Alpha)
	{
		TArray<UWidget> Parts;
		Parts.Add(FIS_Icon);
		Parts.Add(FIS_BtnFrame);
		Parts.Add(FIS_Click);
		Parts.Add(FIS_Track);
		Parts.Add(FIS_Thumb);
		Parts.Add(FIS_ThumbTip1);
		Parts.Add(FIS_ThumbTip2);
		Parts.Add(FIS_ThumbGem);
		Parts.Add(FIS_CapTop);
		Parts.Add(FIS_CapBottom);
		Parts.Add(FIS_BarArea);
		Parts.Add(FIS_Tip);
		for (int i = 0; i < Parts.Num(); i++)
		{
			if (IsValid(Parts[i]) && Parts[i].GetRenderOpacity() != Alpha)
				Parts[i].SetRenderOpacity(Alpha);
		}
	}

	/** The inventory and every activatable screen that contains it. */
	void FIS_CollectActivatables()
	{
		FIS_Activatables.Empty();
		FIS_SeenActive.Empty();
		FIS_ChainWidgets.Empty();
		FIS_AnimSince.Empty();
		UWidget Cur = FIS_Base;
		for (int Guard = 0; Guard < 60 && IsValid(Cur); Guard++)
		{
			UUserWidget AsUserWidget = Cast<UUserWidget>(Cur);
			if (IsValid(AsUserWidget) && !FIS_ChainWidgets.Contains(AsUserWidget))
			{
				FIS_ChainWidgets.Add(AsUserWidget);
				FIS_AnimSince.Add(0);
			}
			UCommonActivatableWidget AsActivatable = Cast<UCommonActivatableWidget>(Cur);
			if (IsValid(AsActivatable) && !FIS_Activatables.Contains(AsActivatable))
			{
				FIS_Activatables.Add(AsActivatable);
				FIS_SeenActive.Add(false);
			}
			UPanelWidget ParentPanel = Cur.GetParent();
			if (IsValid(ParentPanel))
			{
				Cur = ParentPanel;
				continue;
			}
			UObject TreeObj = Cur.GetOuter();
			if (!IsValid(TreeObj))
				break;
			UUserWidget OwnerWidget = Cast<UUserWidget>(TreeObj.GetOuter());
			if (!IsValid(OwnerWidget) || OwnerWidget == Cur)
				break;
			Cur = OwnerWidget;
		}
	}

	/**
	 * False as soon as one of them is deactivated. Widgets that were never active don't count
	 * (some screens may not use activation at all).
	 */
	bool FIS_AllActive()
	{
		bool bAll = true;
		FIS_ActiveInfo = "";
		for (int i = 0; i < FIS_Activatables.Num(); i++)
		{
			UCommonActivatableWidget W = FIS_Activatables[i];
			if (!IsValid(W))
				continue;
			bool bOn = W.IsActivated();
			if (bOn)
				FIS_SeenActive[i] = true;
			else if (FIS_SeenActive[i])
				bAll = false;
			FIS_ActiveInfo += f"{W.GetClass().GetName().ToString()}={bOn}, ";
		}
		return bAll;
	}

	/** True while the inventory or a screen around it plays a (short) animation, e.g. open / close. */
	bool FIS_Animating(int64 NowTicks)
	{
		bool bAny = false;
		FIS_AnimInfo = "";
		for (int i = 0; i < FIS_ChainWidgets.Num(); i++)
		{
			UUserWidget W = FIS_ChainWidgets[i];
			if (!IsValid(W))
				continue;
			if (!W.IsAnyAnimationPlaying())
			{
				FIS_AnimSince[i] = 0;
				continue;
			}
			if (FIS_AnimSince[i] == 0)
				FIS_AnimSince[i] = NowTicks;
			float64 Secs = float64(NowTicks - FIS_AnimSince[i]) / 10000000.0;
			bool bCounts = Secs < FIS_AnimIgnoreAfter;
			if (bCounts)
				bAny = true;
			FString IgnoredNote = bCounts ? "" : " (ignored)";
			FIS_AnimInfo += f"{W.GetClass().GetName().ToString()} {Math::RoundToInt(Secs * 10.0)}/10s{IgnoredNote}, ";
		}
		if (FIS_AnimInfo.IsEmpty())
			FIS_AnimInfo = "none";
		return bAny;
	}

	void FIS_FindParts()
	{
		if (IsValid(FIS_Grid) && IsValid(FIS_Filter))
			return;
		FIS_Inv = Cast<UInventoryMain>(FIS_Base);
		if (!IsValid(FIS_Inv))
		{
			FIS_LastAction = "the screen is not a UInventoryMain";
			return;
		}
		FIS_Grid = FIS_Inv.TileView_Items;
		FIS_Filter = FIS_Inv.GenericFilter;
	}

	bool FIS_IsAllTab()
	{
		if (!IsValid(FIS_Filter) || !IsValid(FIS_Grid))
			return false;
		FGameplayTag Selected = FIS_Filter.GetSelectedFilterTag();
		return Selected.MatchesTagExact(GameplayTag::UI_Filter_Inventory_All);
	}

	/** Is the item dragging part running on this screen? (its widgets are named FIID_...) */
	void FIS_FindDragMod(int64 NowTicks)
	{
		if (FIS_bDragMod || NowTicks < FIS_NextDragModSearch || !IsValid(FIS_Base))
			return;
		FIS_NextDragModSearch = NowTicks + 10000000;   // look again in 1 s

		TArray<UWidget> All;
		FIS_Collect(FIS_Base.GetRootWidget(), All, 0);
		for (int i = 0; i < All.Num(); i++)
		{
			if (IsValid(All[i]) && All[i].GetName().ToString().StartsWith("FIID_"))
			{
				FIS_bDragMod = true;
				return;
			}
		}

		// The drag mod puts its layer into a canvas ABOVE the inventory: check those too.
		UWidget Cur = FIS_Base;
		for (int Guard = 0; Guard < 60 && IsValid(Cur); Guard++)
		{
			UPanelWidget ParentPanel = Cur.GetParent();
			if (IsValid(ParentPanel))
			{
				for (int c = 0; c < ParentPanel.GetChildrenCount(); c++)
				{
					UWidget Child = ParentPanel.GetChildAt(c);
					if (IsValid(Child) && Child.GetName().ToString().StartsWith("FIID_"))
					{
						FIS_bDragMod = true;
						return;
					}
				}
				Cur = ParentPanel;
				continue;
			}
			UObject TreeObj = Cur.GetOuter();
			if (!IsValid(TreeObj))
				break;
			UUserWidget OwnerWidget = Cast<UUserWidget>(TreeObj.GetOuter());
			if (!IsValid(OwnerWidget) || OwnerWidget == Cur)
				break;
			Cur = OwnerWidget;
		}
	}

	// ------------------------------------------------------------------
	//  The button
	// ------------------------------------------------------------------

	/**
	 * The item-count number under the grid: a text that is only a number, below the grid and on
	 * its right half. The one closest to the grid's bottom-right corner wins.
	 */
	UTextBlock FIS_FindCountText()
	{
		FGeometry GridGeo = FIS_Grid.GetCachedGeometry();
		FVector2D GridLocal = GridGeo.GetLocalSize();
		if (GridLocal.X <= 0.0 || GridLocal.Y <= 0.0)
		{
			FIS_CountInfo = "grid not drawn yet";
			return nullptr;
		}
		FVector2D GridTL = GridGeo.LocalToAbsolute(FVector2D(0.0, 0.0));
		FVector2D GridBR = GridGeo.LocalToAbsolute(GridLocal);
		float64 GridH = GridBR.Y - GridTL.Y;
		float64 GridMidX = (GridTL.X + GridBR.X) * 0.5;

		TArray<UWidget> All;
		FIS_Collect(FIS_Base.GetRootWidget(), All, 0);

		UTextBlock Best = nullptr;
		float64 BestScore = 1.0e12;
		FString Seen = "";
		for (int i = 0; i < All.Num(); i++)
		{
			UTextBlock T = Cast<UTextBlock>(All[i]);
			if (!IsValid(T) || !T.IsVisible())
				continue;
			FString TextName = T.GetName().ToString();
			if (TextName.StartsWith("FIS_") || TextName.StartsWith("FIID_"))
				continue;
			FString S = T.GetText().ToString().TrimStartAndEnd();
			if (S.IsEmpty() || !S.IsNumeric())
				continue;

			FGeometry G = T.GetCachedGeometry();
			FVector2D LocalSz = G.GetLocalSize();
			if (LocalSz.X <= 0.0 || LocalSz.Y <= 0.0)
				continue;
			FVector2D TL = G.LocalToAbsolute(FVector2D(0.0, 0.0));
			FVector2D BR = G.LocalToAbsolute(LocalSz);
			Seen += f"{TextName}='{S}' @({Math::RoundToInt(TL.X)},{Math::RoundToInt(TL.Y)}), ";

			if (TL.Y < GridBR.Y - GridH * 0.05 || TL.Y > GridBR.Y + GridH * 0.6)
				continue;
			if (BR.X < GridMidX)
				continue;
			float64 Score = Math::Abs(BR.X - GridBR.X) + Math::Abs(TL.Y - GridBR.Y);
			if (Score < BestScore)
			{
				BestScore = Score;
				Best = T;
			}
		}
		if (IsValid(Best))
			FIS_CountInfo = f"{Best.GetName().ToString()} = '{Best.GetText().ToString()}'";
		else
			FIS_CountInfo = f"not found. number texts: {Seen}";
		return Best;
	}

	/**
	 * The inventory's Close button: a visible widget with "Close" in its name, below the item grid
	 * and less wide than the grid. The biggest such widget wins (the button, not its text).
	 */
	UWidget FIS_FindCloseButton()
	{
		FGeometry GridGeo = FIS_Grid.GetCachedGeometry();
		FVector2D GridLocal = GridGeo.GetLocalSize();
		if (GridLocal.X <= 0.0 || GridLocal.Y <= 0.0)
			return nullptr;
		FVector2D GridTL = GridGeo.LocalToAbsolute(FVector2D(0.0, 0.0));
		FVector2D GridBR = GridGeo.LocalToAbsolute(GridLocal);
		float64 GridW = GridBR.X - GridTL.X;

		TArray<UWidget> All;
		FIS_Collect(FIS_Base.GetRootWidget(), All, 0);
		UWidget Best = nullptr;
		float64 BestArea = 0.0;
		FIS_CloseParts.Empty();
		for (int i = 0; i < All.Num(); i++)
		{
			UWidget W = All[i];
			if (!IsValid(W) || !W.IsVisible())
				continue;
			FString WName = W.GetName().ToString();
			if (!WName.Contains("Close") || WName.StartsWith("FIS_") || WName.StartsWith("FIID_"))
				continue;
			FGeometry G = W.GetCachedGeometry();
			FVector2D LocalSz = G.GetLocalSize();
			if (LocalSz.X <= 0.0 || LocalSz.Y <= 0.0)
				continue;
			FVector2D TL = G.LocalToAbsolute(FVector2D(0.0, 0.0));
			FVector2D BR = G.LocalToAbsolute(LocalSz);
			if (TL.Y < GridBR.Y - 2.0 || BR.X - TL.X > GridW * 0.8)
				continue;
			FIS_CloseParts.Add(W);
			// The whole button: also everything inside a "Close" user widget / panel.
			TArray<UWidget> Inner;
			FIS_Collect(W, Inner, 0);
			for (int k = 0; k < Inner.Num(); k++)
			{
				if (IsValid(Inner[k]) && !FIS_CloseParts.Contains(Inner[k]))
					FIS_CloseParts.Add(Inner[k]);
			}
			float64 Area = (BR.X - TL.X) * (BR.Y - TL.Y);
			if (Area > BestArea)
			{
				BestArea = Area;
				Best = W;
			}
		}
		if (!IsValid(Best))
			return nullptr;

		// Climb to the container around it while it is still button-sized (frame of the button).
		FVector2D BestSz = Best.GetCachedGeometry().GetAbsoluteSize();
		UWidget Root = Best;
		for (int Lvl = 0; Lvl < 4; Lvl++)
		{
			UWidget Up = Root.GetParent();
			if (!IsValid(Up))
			{
				UObject TreeObj = Root.GetOuter();
				UUserWidget OwnerWidget = IsValid(TreeObj) ? Cast<UUserWidget>(TreeObj.GetOuter()) : nullptr;
				if (!IsValid(OwnerWidget) || OwnerWidget == Root)
					break;
				Up = OwnerWidget;
			}
			FVector2D UpSz = Up.GetCachedGeometry().GetAbsoluteSize();
			if (UpSz.X <= 0.0 || UpSz.X > GridW * 0.8 || UpSz.Y > BestSz.Y * 2.5)
				break;
			Root = Up;
		}
		TArray<UWidget> RootParts;
		FIS_Collect(Root, RootParts, 0);
		for (int k = 0; k < RootParts.Num(); k++)
		{
			if (IsValid(RootParts[k]) && !FIS_CloseParts.Contains(RootParts[k]))
				FIS_CloseParts.Add(RootParts[k]);
		}
		return Best;
	}

	/**
	 * Gives the Sort button the background and frame of the game's Close button: its button
	 * style (normal / hover / pressed), else its frame picture, else the game's common button
	 * textures loaded by name.
	 */
	void FIS_ApplyButtonStyle()
	{
		if (FIS_bBtnStyled || !IsValid(FIS_BtnFrame))
			return;

		// 1) The Close button's own button style.
		for (int i = 0; i < FIS_CloseParts.Num(); i++)
		{
			UCommonButtonBase Btn = Cast<UCommonButtonBase>(FIS_CloseParts[i]);
			if (!IsValid(Btn))
				continue;
			UCommonButtonStyle Style = Btn.GetStyle();
			if (!IsValid(Style))
				continue;
			Style.GetNormalBaseBrush(FIS_BtnBrushNormal);
			Style.GetNormalHoveredBrush(FIS_BtnBrushHover);
			Style.GetNormalPressedBrush(FIS_BtnBrushPressed);
			FIS_bBtnStyled = true;
			FIS_BtnBrushState = -1;
			FIS_BtnStyleInfo = f"style of {Btn.GetName().ToString()}";
			return;
		}

		// 2) The biggest picture inside the Close button (its background / frame).
		UImage Biggest = nullptr;
		float64 BiggestArea = 0.0;
		for (int i = 0; i < FIS_CloseParts.Num(); i++)
		{
			UImage Img = Cast<UImage>(FIS_CloseParts[i]);
			if (!IsValid(Img) || !Img.IsVisible())
				continue;
			FVector2D Sz = Img.GetCachedGeometry().GetAbsoluteSize();
			if (Sz.X * Sz.Y > BiggestArea)
			{
				BiggestArea = Sz.X * Sz.Y;
				Biggest = Img;
			}
		}
		if (IsValid(Biggest) && BiggestArea > 0.0)
		{
			FIS_BtnBrushNormal = Biggest.Brush;
			FIS_BtnBrushHover = Biggest.Brush;
			FIS_BtnBrushPressed = Biggest.Brush;
			FIS_bBtnStyled = true;
			FIS_BtnBrushState = -1;
			FIS_BtnStyleInfo = f"picture {Biggest.GetName().ToString()}";
			return;
		}

		// 3) The game's common button textures (once, until the Close button is found).
		if (FIS_bBtnFallbackDone)
			return;
		FIS_bBtnFallbackDone = true;
		UTexture2D NormalTex = Cast<UTexture2D>(LoadObject(nullptr, "/Game/UI/Textures/Common/T_CommonButton_Default.T_CommonButton_Default"));
		UTexture2D HoverTex = Cast<UTexture2D>(LoadObject(nullptr, "/Game/UI/Textures/Common/T_CommonButton_Hover.T_CommonButton_Hover"));
		if (IsValid(NormalTex))
		{
			FIS_BtnBrushNormal = FIS_BoxBrush(NormalTex);
			FIS_BtnBrushHover = IsValid(HoverTex) ? FIS_BoxBrush(HoverTex) : FIS_BtnBrushNormal;
			FIS_BtnBrushPressed = FIS_BtnBrushHover;
			FIS_BtnBrushState = -1;
			FIS_BtnStyleInfo = "common button textures";
		}
	}

	/** A brush that draws the texture as a 9-slice box (frame keeps its thickness). */
	FSlateBrush FIS_BoxBrush(UTexture2D Tex)
	{
		FIS_BtnFrame.SetBrushFromTexture(Tex, true);
		FSlateBrush B = FIS_BtnFrame.Brush;
		B.DrawAs = ESlateBrushDrawType::Box;
		FMargin M;
		M.Left = float32(0.25);
		M.Top = float32(0.25);
		M.Right = float32(0.25);
		M.Bottom = float32(0.25);
		B.Margin = M;
		return B;
	}

	void FIS_SetButtonBrushState(int State)
	{
		if (!IsValid(FIS_BtnFrame) || State == FIS_BtnBrushState || FIS_BtnStyleInfo == "-")
			return;
		FIS_BtnBrushState = State;
		if (State == 2)
			FIS_BtnFrame.SetBrush(FIS_BtnBrushPressed);
		else if (State == 1)
			FIS_BtnFrame.SetBrush(FIS_BtnBrushHover);
		else
			FIS_BtnFrame.SetBrush(FIS_BtnBrushNormal);
	}

	/** Closes the Sort-by menu without changing anything (click outside it). */
	void FIS_CloseMenu()
	{
		if (!FIS_bMenuOpen)
			return;
		FIS_bMenuOpen = false;
		FIS_bTipDirty = true;
		FIS_LastAction = "sort menu closed (click outside)";
	}

	/** Puts the picture (and the click area) right under the item-count number, right edges aligned. */
	void FIS_PlaceButton(bool bWanted, FVector2D Mouse)
	{
		if (!IsValid(FIS_Icon) || !IsValid(FIS_Click) || !IsValid(FIS_Canvas))
			return;

		bool bShow = bWanted;   // parameters are const in AngelScript
		FVector2D TextLocal;
		if (bShow)
		{
			TextLocal = FIS_CountText.GetCachedGeometry().GetLocalSize();
			if (TextLocal.X <= 0.0 || TextLocal.Y <= 0.0)
				bShow = false;
		}
		if (!bShow)
		{
			if (FIS_bShown)
			{
				FIS_Icon.SetVisibility(ESlateVisibility::Collapsed);
				if (IsValid(FIS_BtnFrame))
					FIS_BtnFrame.SetVisibility(ESlateVisibility::Collapsed);
				FIS_Click.SetVisibility(ESlateVisibility::Collapsed);
				FIS_bShown = false;
			}
			FIS_bHover = false;
			FIS_Click.FIS_bDown = false;
			return;
		}

		FGeometry TextGeo = FIS_CountText.GetCachedGeometry();
		FVector2D TextTL = TextGeo.LocalToAbsolute(FVector2D(0.0, 0.0));
		FVector2D TextBR = TextGeo.LocalToAbsolute(TextLocal);
		float64 TextH = TextBR.Y - TextTL.Y;

		float64 IconH = TextH * FIS_IconHeight;
		float64 IconW = IconH * FIS_IconAspect;
		float64 IconTop = TextBR.Y + TextH * FIS_Gap + TextH * FIS_OffsetY;

		// Same height and level as the Close button, if it is there.
		if (IsValid(FIS_CloseBtn))
		{
			// Outline of all visible parts of the Close button together (frame + key + text).
			float64 CloseTop = 1.0e12;
			float64 CloseBottom = -1.0e12;
			for (int i = 0; i < FIS_CloseParts.Num(); i++)
			{
				UWidget Part = FIS_CloseParts[i];
				if (!IsValid(Part) || !Part.IsVisible())
					continue;
				FGeometry PartGeo = Part.GetCachedGeometry();
				FVector2D PartLocal = PartGeo.GetLocalSize();
				if (PartLocal.X <= 0.0 || PartLocal.Y <= 0.0)
					continue;
				float64 PartTop = PartGeo.LocalToAbsolute(FVector2D(0.0, 0.0)).Y;
				float64 PartBottom = PartGeo.LocalToAbsolute(PartLocal).Y;
				if (PartTop < CloseTop)
					CloseTop = PartTop;
				if (PartBottom > CloseBottom)
					CloseBottom = PartBottom;
			}
			float64 CloseH = CloseBottom - CloseTop;
			if (CloseH > 1.0 && CloseH < 1000.0)
			{
				IconH = CloseH * FIS_CloseHeightScale;
				IconTop = CloseTop + TextH * FIS_OffsetY;   // top edges aligned
			}
		}

		IconH = IconH * FIS_ButtonScale;
		IconW = IconH * (FIS_ShowButtonFrame ? FIS_IconAspect : FIS_SymbolAspect);
		FIS_BtnAbsSize = FVector2D(IconW, IconH);
		FIS_BtnAbsPos = FVector2D(TextBR.X - IconW + TextH * FIS_OffsetX, IconTop);

		// Hover / press look.
		FIS_bHover = Mouse.X >= FIS_BtnAbsPos.X && Mouse.X <= FIS_BtnAbsPos.X + IconW
			&& Mouse.Y >= FIS_BtnAbsPos.Y && Mouse.Y <= FIS_BtnAbsPos.Y + IconH;
		if (!FIS_bHover)
			FIS_Click.FIS_bDown = false;
		float64 Scale = 1.0;
		if (FIS_bHover)
			Scale = FIS_Click.FIS_bDown ? FIS_PressScale : FIS_HoverScale;
		FIS_Icon.SetColorAndOpacity(FIS_bHover ? FIS_ColorHover : FIS_ColorNormal);
		if (FIS_ShowButtonFrame)
			FIS_ApplyButtonStyle();
		if (FIS_ShowButtonFrame)
			FIS_SetButtonBrushState(!FIS_bHover ? 0 : (FIS_Click.FIS_bDown ? 2 : 1));

		// Screen pixels -> our canvas.
		FGeometry CanvasGeo = FIS_Canvas.GetCachedGeometry();
		float64 AbsW = CanvasGeo.GetAbsoluteSize().X;
		float64 PxScale = AbsW > 0.0 ? CanvasGeo.GetLocalSize().X / AbsW : 1.0;
		FVector2D LocalPos = CanvasGeo.AbsoluteToLocal(FIS_BtnAbsPos);
		FVector2D LocalSize = FIS_BtnAbsSize * PxScale;

		// Frame over the whole button, the arrows centred in it.
		if (IsValid(FIS_BtnFrame) && FIS_ShowButtonFrame)
			FIS_PlaceAt(FIS_BtnFrame, LocalPos, LocalSize, Scale);
		float64 SymbolPart = FIS_ShowButtonFrame ? FIS_SymbolHeight : 1.0;
		FVector2D SymbolSize = FVector2D(LocalSize.Y * SymbolPart * FIS_SymbolAspect, LocalSize.Y * SymbolPart);
		FIS_PlaceAt(FIS_Icon, LocalPos + (LocalSize - SymbolSize) * 0.5, SymbolSize, Scale);
		FIS_PlaceAt(FIS_Click, LocalPos, LocalSize, 1.0);

		if (!FIS_bShown)
		{
			FIS_Icon.SetVisibility(ESlateVisibility::HitTestInvisible);
			if (IsValid(FIS_BtnFrame) && FIS_ShowButtonFrame)
				FIS_BtnFrame.SetVisibility(ESlateVisibility::HitTestInvisible);
			FIS_Click.SetVisibility(ESlateVisibility::Visible);
			FIS_bShown = true;
		}
	}

	/**
	 * Slot stays at the top-left corner with a fixed size; the widget is moved with its render
	 * transform only, so it never changes the size of the game's panels.
	 */
	void FIS_PlaceAt(UWidget W, FVector2D LocalPos, FVector2D LocalSize, float64 Scale)
	{
		UCanvasPanelSlot WSlot = Cast<UCanvasPanelSlot>(W.Slot);
		if (IsValid(WSlot))
		{
			WSlot.SetPosition(FVector2D(0.0, 0.0));
			WSlot.SetSize(LocalSize);
		}
		W.SetRenderTransformPivot(FVector2D(0.5, 0.5));
		W.SetRenderTranslation(LocalPos);
		W.SetRenderScale(FVector2D(Scale, Scale));
	}

	// ------------------------------------------------------------------
	//  Scroll bar
	// ------------------------------------------------------------------

	int FIS_MaxScroll()
	{
		int MaxOffset = FIS_Grid.GetNumRows() - FIS_Grid.GetViewHeight();
		return MaxOffset > 0 ? MaxOffset : 0;
	}

	void FIS_UpdateScrollBar(bool bWanted, FVector2D Mouse)
	{
		if (!IsValid(FIS_Track) || !IsValid(FIS_Thumb) || !IsValid(FIS_BarArea))
			return;

		bool bShow = bWanted;
		FGeometry GridGeo;
		FVector2D GridLocal;
		if (bShow)
		{
			GridGeo = FIS_Grid.GetCachedGeometry();
			GridLocal = GridGeo.GetLocalSize();
			if (GridLocal.X <= 0.0 || GridLocal.Y <= 0.0)
				bShow = false;
		}
		if (!bShow)
		{
			if (FIS_bBarShown)
			{
				FIS_Track.SetVisibility(ESlateVisibility::Collapsed);
				FIS_Thumb.SetVisibility(ESlateVisibility::Collapsed);
				FIS_SetHandleExtrasVisibility(ESlateVisibility::Collapsed);
				FIS_BarArea.SetVisibility(ESlateVisibility::Collapsed);
				if (IsValid(FIS_CapTop))
					FIS_CapTop.SetVisibility(ESlateVisibility::Collapsed);
				if (IsValid(FIS_CapBottom))
					FIS_CapBottom.SetVisibility(ESlateVisibility::Collapsed);
				FIS_bBarShown = false;
			}
			FIS_bBarDragging = false;
			return;
		}

		FVector2D GridTL = GridGeo.LocalToAbsolute(FVector2D(0.0, 0.0));
		FVector2D GridBR = GridGeo.LocalToAbsolute(GridLocal);
		float64 AbsPerLocal = (GridBR.X - GridTL.X) / GridLocal.X;

		// One tile's width in screen pixels (from the grid's item width, else grid width / columns).
		float64 TileW = FIS_Grid.m_ItemWidth * AbsPerLocal;
		if (TileW < 4.0)
		{
			int Cols = FIS_Grid.GetNumColumns();
			TileW = (GridBR.X - GridTL.X) / float64(Cols > 0 ? Cols : 5);
		}

		// The rail runs along the grid's height, right of the grid.
		float64 BarX = GridBR.X + TileW * FIS_BarOffsetX;
		FIS_TrackTop = GridTL.Y + TileW * (FIS_BarOffsetY + FIS_BarTopInset);
		FIS_TrackLen = (GridBR.Y - GridTL.Y) - TileW * (FIS_BarTopInset + FIS_BarBottomInset);
		float64 CapClear = TileW * (FIS_CapSize * 0.5 + FIS_CapGap);
		FIS_SlideTop = FIS_TrackTop + CapClear;
		FIS_SlideLen = FIS_TrackLen - CapClear * 2.0;
		if (FIS_SlideLen < 1.0)
			FIS_SlideLen = 1.0;
		FIS_ThumbLen = FIS_TrackLen * FIS_ThumbLength;
		if (FIS_ThumbLen > FIS_SlideLen)
			FIS_ThumbLen = FIS_SlideLen;
		float64 Range = FIS_SlideLen - FIS_ThumbLen;

		int MaxOffset = FIS_MaxScroll();
		int Offset = FIS_Grid.GetCurrentScrollOffset();
		if (FIS_bBarDragging)
		{
			FIS_ThumbTop = FIS_DragThumbTop;   // follows the mouse smoothly
		}
		else
		{
			float64 Frac = MaxOffset > 0 ? float64(Offset) / float64(MaxOffset) : 0.0;
			FIS_ThumbTop = FIS_SlideTop + Range * Math::Clamp(Frac, 0.0, 1.0);
		}

		float64 ThumbW = TileW * FIS_ThumbWidth;
		float64 TrackW = TileW * FIS_TrackWidth;
		float64 HitW = TileW * FIS_HitWidth;
		float64 CapS = TileW * FIS_CapSize;

		bool bHover = Mouse.X >= BarX - HitW * 0.5 && Mouse.X <= BarX + HitW * 0.5
			&& Mouse.Y >= FIS_TrackTop && Mouse.Y <= FIS_TrackTop + FIS_TrackLen;
		FLinearColor HandleTint = (bHover || FIS_bBarDragging) ? FLinearColor(1.0, 1.0, 1.0, 1.0) : FLinearColor(0.80, 0.80, 0.80, 1.0);
		FIS_Thumb.SetColorAndOpacity(HandleTint);
		if (IsValid(FIS_ThumbTip1))
			FIS_ThumbTip1.SetColorAndOpacity(HandleTint);
		if (IsValid(FIS_ThumbTip2))
			FIS_ThumbTip2.SetColorAndOpacity(HandleTint);
		if (IsValid(FIS_ThumbGem))
			FIS_ThumbGem.SetColorAndOpacity(HandleTint);

		FIS_PlaceAbs(FIS_Track, FVector2D(BarX - TrackW * 0.5, FIS_TrackTop), FVector2D(TrackW, FIS_TrackLen));
		// Handle: point, body, point (the points keep their shape at any length) + diamond in the middle.
		float64 TipH = ThumbW * FIS_ThumbTipAspect;
		float64 BodyLen = FIS_ThumbLen - TipH * 2.0;
		if (BodyLen < 0.0)
			BodyLen = 0.0;
		FIS_PlaceAbs(FIS_Thumb, FVector2D(BarX - ThumbW * 0.5, FIS_ThumbTop + TipH - 0.5), FVector2D(ThumbW, BodyLen + 1.0));
		if (IsValid(FIS_ThumbTip1))
			FIS_PlaceAbs(FIS_ThumbTip1, FVector2D(BarX - ThumbW * 0.5, FIS_ThumbTop), FVector2D(ThumbW, TipH));
		if (IsValid(FIS_ThumbTip2))
			FIS_PlaceAbs(FIS_ThumbTip2, FVector2D(BarX - ThumbW * 0.5, FIS_ThumbTop + FIS_ThumbLen - TipH), FVector2D(ThumbW, TipH));
		float64 GemS = TileW * FIS_GemSize;
		if (IsValid(FIS_ThumbGem))
			FIS_PlaceAbs(FIS_ThumbGem, FVector2D(BarX - GemS * 0.5, FIS_ThumbTop + FIS_ThumbLen * 0.5 - GemS * 0.5), FVector2D(GemS, GemS));
		FIS_PlaceAbs(FIS_BarArea, FVector2D(BarX - HitW * 0.5, FIS_TrackTop), FVector2D(HitW, FIS_TrackLen));
		if (IsValid(FIS_CapTop))
			FIS_PlaceAbs(FIS_CapTop, FVector2D(BarX - CapS * 0.5, FIS_TrackTop - CapS * 0.5), FVector2D(CapS, CapS));
		if (IsValid(FIS_CapBottom))
			FIS_PlaceAbs(FIS_CapBottom, FVector2D(BarX - CapS * 0.5, FIS_TrackTop + FIS_TrackLen - CapS * 0.5), FVector2D(CapS, CapS));

		if (!FIS_bBarShown)
		{
			FIS_Track.SetVisibility(ESlateVisibility::HitTestInvisible);
			FIS_Thumb.SetVisibility(ESlateVisibility::HitTestInvisible);
			FIS_SetHandleExtrasVisibility(ESlateVisibility::HitTestInvisible);
			FIS_BarArea.SetVisibility(ESlateVisibility::Visible);
			if (IsValid(FIS_CapTop))
				FIS_CapTop.SetVisibility(ESlateVisibility::HitTestInvisible);
			if (IsValid(FIS_CapBottom))
				FIS_CapBottom.SetVisibility(ESlateVisibility::HitTestInvisible);
			FIS_bBarShown = true;
		}
		FIS_BarInfo = f"rows {FIS_Grid.GetNumRows()}, view {FIS_Grid.GetViewHeight()}, offset {Offset}/{MaxOffset}, tile {Math::RoundToInt(TileW)} px, rail x {Math::RoundToInt(BarX)} y {Math::RoundToInt(FIS_TrackTop)} len {Math::RoundToInt(FIS_TrackLen)}";
	}

	void FIS_SetHandleExtrasVisibility(ESlateVisibility Vis)
	{
		if (IsValid(FIS_ThumbTip1))
			FIS_ThumbTip1.SetVisibility(Vis);
		if (IsValid(FIS_ThumbTip2))
			FIS_ThumbTip2.SetVisibility(Vis);
		if (IsValid(FIS_ThumbGem))
			FIS_ThumbGem.SetVisibility(Vis);
	}

	/** Left press on the bar: on the handle = grab it; on the rail = jump there and grab. */
	void FIS_BarPress(FVector2D P)
	{
		if (!IsValid(FIS_Grid))
			return;
		if (P.Y >= FIS_ThumbTop && P.Y <= FIS_ThumbTop + FIS_ThumbLen)
			FIS_BarGrabY = P.Y - FIS_ThumbTop;
		else
			FIS_BarGrabY = FIS_ThumbLen * 0.5;
		FIS_bBarDragging = true;
		FIS_BarDrag(P);
	}

	void FIS_BarDrag(FVector2D P)
	{
		if (!IsValid(FIS_Grid))
			return;
		float64 Range = FIS_SlideLen - FIS_ThumbLen;
		float64 Top = Math::Clamp(P.Y - FIS_BarGrabY, FIS_SlideTop, FIS_SlideTop + (Range > 0.0 ? Range : 0.0));
		FIS_DragThumbTop = Top;
		int MaxOffset = FIS_MaxScroll();
		float64 Frac = Range > 0.0 ? (Top - FIS_SlideTop) / Range : 0.0;
		int Wanted = Math::RoundToInt(Frac * float64(MaxOffset));
		if (Wanted != FIS_Grid.GetCurrentScrollOffset())
			FIS_Grid.SetScrollOffset(Wanted);
	}

	void FIS_BarWheel(float64 Delta)
	{
		if (!IsValid(FIS_Grid) || Delta == 0.0)
			return;
		int Step = Delta > 0.0 ? -1 : 1;
		int Wanted = FIS_Grid.GetCurrentScrollOffset() + Step;
		int MaxOffset = FIS_MaxScroll();
		if (Wanted < 0)
			Wanted = 0;
		if (Wanted > MaxOffset)
			Wanted = MaxOffset;
		FIS_Grid.SetScrollOffset(Wanted);
	}

	/** Places a widget at a screen-pixel rectangle on our canvas. */
	void FIS_PlaceAbs(UWidget W, FVector2D AbsPos, FVector2D AbsSize)
	{
		FGeometry CanvasGeo = FIS_Canvas.GetCachedGeometry();
		float64 AbsW = CanvasGeo.GetAbsoluteSize().X;
		float64 PxScale = AbsW > 0.0 ? CanvasGeo.GetLocalSize().X / AbsW : 1.0;
		FIS_PlaceAt(W, CanvasGeo.AbsoluteToLocal(AbsPos), AbsSize * PxScale, 1.0);
	}

	// ------------------------------------------------------------------
	//  Clicks
	// ------------------------------------------------------------------

	void FIS_OnClick()
	{
		FIS_PlayClickSound();
		if (!FIS_IsAllTab())
		{
			FIS_LastAction = "click ignored: not on the All tab";
			return;
		}
		FIS_SortNow();
		if (!FIS_bDragMod && IsValid(FIS_Settings) && !FIS_Settings.bAutoSort)
		{
			FIS_Settings.bAutoSort = true;
			FIS_SaveSettings();
		}
	}

	// ------------------------------------------------------------------
	//  Tooltip of the Sort button
	// ------------------------------------------------------------------

	void FIS_MakeTooltip(UUserWidget Base, UCanvasPanel Canvas)
	{
		FIS_Tip = Cast<UCanvasPanel>(Base.ConstructWidget(UCanvasPanel, n"FIS_Tip"));
		if (!IsValid(FIS_Tip))
			return;
		FIS_AddSmall(Canvas, FIS_Tip, 20);
		FIS_Tip.SetVisibility(ESlateVisibility::Collapsed);

		// Background: dark panel with the double light frame, drawn as a 9-slice box so the
		// frame keeps its thickness at any size.
		FIS_TipBg = Cast<UImage>(Base.ConstructWidget(UImage, n"FIS_TipBg"));
		if (IsValid(FIS_TipBg))
		{
			FIS_Tip.AddChildToCanvas(FIS_TipBg);
			UTexture2D BgTex = FIS_LoadTexture("TooltipBg.png");
			if (IsValid(BgTex))
			{
				FIS_TipBg.SetBrushFromTexture(BgTex, true);
				FSlateBrush BgBrush = FIS_TipBg.Brush;
				BgBrush.DrawAs = ESlateBrushDrawType::Box;
				FMargin BoxMargin;
				BoxMargin.Left = float32(10.0 / 64.0);
				BoxMargin.Top = float32(10.0 / 64.0);
				BoxMargin.Right = float32(10.0 / 64.0);
				BoxMargin.Bottom = float32(10.0 / 64.0);
				BgBrush.Margin = BoxMargin;
				FIS_TipBg.SetBrush(BgBrush);
			}
		}

		// Frame of the game's tooltip (filled in by FIS_TipApplyGameStyle).
		FIS_TipOutline = Cast<UImage>(Base.ConstructWidget(UImage, n"FIS_TipOutline"));
		if (IsValid(FIS_TipOutline))
		{
			UCanvasPanelSlot OutlineSlot = FIS_Tip.AddChildToCanvas(FIS_TipOutline);
			if (IsValid(OutlineSlot))
				OutlineSlot.SetZOrder(1);
			FIS_TipOutline.SetVisibility(ESlateVisibility::Collapsed);
		}

		FIS_TipTitleText = FIS_MakeTipText(Base, n"FIS_TipTitleText", FIS_TipTitle);
		FIS_TipActionText = FIS_MakeTipText(Base, n"FIS_TipActionText", FIS_TipAction);
		if (IsValid(FIS_TipActionText))
		{
			FSlateColor ActionColor;
			ActionColor.SpecifiedColor = FIS_TipActionColor;
			FIS_TipActionText.SetColorAndOpacity(ActionColor);
		}

		// The right-click menu entries (shown only while the menu is open).
		FIS_MenuOptions.Empty();
		FIS_MenuOptions.Add("1. Categories");
		FIS_MenuOptions.Add("2. Values");
		FIS_MenuOptions.Add("3. Stack all items");
		FIS_MenuOptionActive.Empty();
		FIS_MenuOptionActive.Add(true);    // Categories
		FIS_MenuOptionActive.Add(true);    // Values
		FIS_MenuOptionActive.Add(true);    // Stack all items (on/off, part 3)
		FIS_TipOptionTexts.Empty();
		FIS_TipOptionMarks.Empty();
		FIS_TipOptionAreas.Empty();
		for (int i = 0; i < FIS_MenuOptions.Num(); i++)
		{
			UImage Mark = Cast<UImage>(Base.ConstructWidget(UImage, FName(f"FIS_TipMark{i}")));
			if (IsValid(Mark))
			{
				UCanvasPanelSlot MarkSlot = FIS_Tip.AddChildToCanvas(Mark);
				if (IsValid(MarkSlot))
					MarkSlot.SetZOrder(3);
				UTexture2D MarkTex = FIS_LoadTexture("ScrollCap.png");
				if (IsValid(MarkTex))
					Mark.SetBrushFromTexture(MarkTex, false);
				Mark.SetVisibility(ESlateVisibility::Collapsed);
			}
			FIS_TipOptionMarks.Add(Mark);
			FIS_TipOptionAreas.Add(FIS_MakeMenuArea(Base, FName(f"FIS_TipArea{i}"), i));
		
			UTextBlock Opt = FIS_MakeTipText(Base, FName(f"FIS_TipOption{i}"), FIS_MenuOptions[i]);
			if (IsValid(Opt))
			{
				FSlateColor OptColor;
				OptColor.SpecifiedColor = FIS_MenuOptionColor;
				Opt.SetColorAndOpacity(OptColor);
				Opt.SetVisibility(ESlateVisibility::Collapsed);
			}
			FIS_TipOptionTexts.Add(Opt);
		}

		// Thin divider line (an image without picture draws a plain box in its colour).
		FIS_TipLine = Cast<UImage>(Base.ConstructWidget(UImage, n"FIS_TipLine"));
		if (IsValid(FIS_TipLine))
		{
			UCanvasPanelSlot LineSlot = FIS_Tip.AddChildToCanvas(FIS_TipLine);
			if (IsValid(LineSlot))
				LineSlot.SetZOrder(2);
			FIS_TipLine.SetColorAndOpacity(FLinearColor(0.80, 0.67, 0.60, 0.55));
		}

		// Apply button: frame + text + click area.
		FIS_TipApplyFrame = Cast<UImage>(Base.ConstructWidget(UImage, n"FIS_TipApplyFrame"));
		if (IsValid(FIS_TipApplyFrame))
		{
			UCanvasPanelSlot FrameSlot = FIS_Tip.AddChildToCanvas(FIS_TipApplyFrame);
			if (IsValid(FrameSlot))
				FrameSlot.SetZOrder(2);
			UTexture2D FrameTex = FIS_LoadTexture("ButtonFrame.png");
			if (IsValid(FrameTex))
			{
				FIS_TipApplyFrame.SetBrushFromTexture(FrameTex, true);
				FSlateBrush FrameBrush = FIS_TipApplyFrame.Brush;
				FrameBrush.DrawAs = ESlateBrushDrawType::Box;
				FMargin FrameMargin;
				FrameMargin.Left = float32(6.0 / 48.0);
				FrameMargin.Top = float32(6.0 / 48.0);
				FrameMargin.Right = float32(6.0 / 48.0);
				FrameMargin.Bottom = float32(6.0 / 48.0);
				FrameBrush.Margin = FrameMargin;
				FIS_TipApplyFrame.SetBrush(FrameBrush);
			}
			FIS_TipApplyFrame.SetVisibility(ESlateVisibility::Collapsed);
		}
		FIS_TipApplyText = FIS_MakeTipText(Base, n"FIS_TipApplyText", FIS_ApplyText);
		if (IsValid(FIS_TipApplyText))
			FIS_TipApplyText.SetVisibility(ESlateVisibility::Collapsed);
		FIS_TipApplyArea = FIS_MakeMenuArea(Base, n"FIS_TipApplyArea", -1);

		FIS_TipMouse = Cast<UImage>(Base.ConstructWidget(UImage, n"FIS_TipMouse"));
		if (IsValid(FIS_TipMouse))
		{
			UCanvasPanelSlot MouseSlot = FIS_Tip.AddChildToCanvas(FIS_TipMouse);
			if (IsValid(MouseSlot))
				MouseSlot.SetZOrder(3);
			UTexture2D MouseTex = FIS_LoadTexture("MouseRMB.png");
			if (IsValid(MouseTex))
				FIS_TipMouse.SetBrushFromTexture(MouseTex, false);
		}
	}

	UFIS_MenuItemArea FIS_MakeMenuArea(UUserWidget Base, FName WidgetName, int Index)
	{
		UFIS_MenuItemArea Area = Cast<UFIS_MenuItemArea>(Base.ConstructWidget(UFIS_MenuItemArea, WidgetName));
		if (!IsValid(Area))
			return nullptr;
		Area.FIS_Layer = this;
		Area.FIS_Index = Index;
		UCanvasPanelSlot AreaSlot = FIS_Tip.AddChildToCanvas(Area);
		if (IsValid(AreaSlot))
			AreaSlot.SetZOrder(5);
		Area.SetVisibility(ESlateVisibility::Collapsed);
		return Area;
	}

	UTextBlock FIS_MakeTipText(UUserWidget Base, FName WidgetName, FString Content)
	{
		UTextBlock T = Cast<UTextBlock>(Base.ConstructWidget(UTextBlock, WidgetName));
		if (!IsValid(T))
			return nullptr;
		UCanvasPanelSlot TextSlot = FIS_Tip.AddChildToCanvas(T);
		if (IsValid(TextSlot))
		{
			TextSlot.SetAutoSize(true);
			TextSlot.SetZOrder(3);
		}
		T.SetText(FText::FromString(Content));
		FSlateColor TextColor;
		TextColor.SpecifiedColor = FLinearColor(0.84, 0.75, 0.70, 1.0);
		T.SetColorAndOpacity(TextColor);
		T.SetShadowOffset(FVector2D(1.0, 1.0));
		T.SetShadowColorAndOpacity(FLinearColor(0.0, 0.0, 0.0, 0.8));
		return T;
	}

	/**
	 * Uses the game's own tooltip graphics. First choice: copy the brushes (texture + how it is
	 * drawn) from the game's item tooltip (W_Inventory_ItemTooltip) on this screen. If that is
	 * not found yet, load the same textures by path once (the copy is tried again next time).
	 */
	void FIS_TipApplyGameStyle()
	{
		if (FIS_bTipGameStyle)
			return;

		bool bHaveBg = false;
		bool bHaveOutline = false;
		bool bHaveLine = false;
		FSlateBrush BgBrush;
		FSlateBrush OutlineBrush;
		FSlateBrush LineBrush;
		FSlateFontInfo GameTitleFont;
		float64 GameTitleSize = -1.0;

		TArray<UWidget> All;
		FIS_Collect(FIS_Base.GetRootWidget(), All, 0);
		for (int i = 0; i < All.Num(); i++)
		{
			UUserWidget Tooltip = Cast<UUserWidget>(All[i]);
			if (!IsValid(Tooltip))
				continue;
			FString ClassName = Tooltip.GetClass().GetName().ToString();
			if (!ClassName.Contains("ItemTooltip") || ClassName.Contains("Slot"))
				continue;

			TArray<UWidget> Inner;
			FIS_Collect(Tooltip.GetRootWidget(), Inner, 0);
			for (int k = 0; k < Inner.Num(); k++)
			{
				UImage Img = Cast<UImage>(Inner[k]);
				if (IsValid(Img))
				{
					UObject Res = Widget::GetBrushResource(Img.Brush);
					FString ResName = IsValid(Res) ? Res.GetName().ToString() : "";
					if (!bHaveBg && (ResName.Contains("TooltipBackground") || ResName.Contains("Tooltip_Background")))
					{
						BgBrush = Img.Brush;
						bHaveBg = true;
					}
					else if (!bHaveOutline && ResName.Contains("Outline"))
					{
						OutlineBrush = Img.Brush;
						bHaveOutline = true;
					}
					else if (!bHaveLine && ResName.Contains("TitleLine") && !ResName.Contains("Vertical"))
					{
						LineBrush = Img.Brush;
						bHaveLine = true;
					}
					continue;
				}
				UTextBlock T = Cast<UTextBlock>(Inner[k]);
				if (IsValid(T))
				{
					FSlateFontInfo F = T.GetFont();
					if (F.Size > GameTitleSize)
					{
						GameTitleSize = F.Size;
						GameTitleFont = F;
					}
				}
			}
			if (bHaveBg || bHaveOutline)
				break;
		}

		if (bHaveBg || bHaveOutline)
		{
			if (bHaveBg)
				FIS_TipBg.SetBrush(BgBrush);
			if (bHaveOutline && IsValid(FIS_TipOutline))
			{
				FIS_TipOutline.SetBrush(OutlineBrush);
				FIS_TipOutline.SetVisibility(ESlateVisibility::HitTestInvisible);
			}
			if (bHaveLine && IsValid(FIS_TipLine))
				FIS_SetTipLineBrush(LineBrush);
			if (GameTitleSize > 0.0 && IsValid(FIS_TipTitleText))
				FIS_TipTitleText.SetFont(GameTitleFont);
			FIS_bTipGameStyle = true;
			return;
		}

		// Not found (yet): the same textures, loaded by path.
		if (FIS_bTipFallbackDone)
			return;
		FIS_bTipFallbackDone = true;
		UTexture2D BgTex = Cast<UTexture2D>(LoadObject(nullptr, "/Game/UI/Textures/ManagementUI/Inventory/T_ItemTooltip_Background2.T_ItemTooltip_Background2"));
		UTexture2D OutlineTex = Cast<UTexture2D>(LoadObject(nullptr, "/Game/UI/Textures/ManagementUI/Glossary/T_ItemTooltip_Outline4.T_ItemTooltip_Outline4"));
		UTexture2D LineTex = Cast<UTexture2D>(LoadObject(nullptr, "/Game/UI/Textures/ManagementUI/Inventory/T_TooltipTitleLine.T_TooltipTitleLine"));
		if (IsValid(BgTex))
			FIS_TipBg.SetBrushFromTexture(BgTex, false);
		if (IsValid(OutlineTex) && IsValid(FIS_TipOutline))
		{
			FIS_TipOutline.SetBrushFromTexture(OutlineTex, true);
			FSlateBrush OBrush = FIS_TipOutline.Brush;
			OBrush.DrawAs = ESlateBrushDrawType::Box;
			FMargin OMargin;
			OMargin.Left = float32(0.3);
			OMargin.Top = float32(0.3);
			OMargin.Right = float32(0.3);
			OMargin.Bottom = float32(0.3);
			OBrush.Margin = OMargin;
			FIS_TipOutline.SetBrush(OBrush);
			FIS_TipOutline.SetVisibility(ESlateVisibility::HitTestInvisible);
		}
		if (IsValid(LineTex) && IsValid(FIS_TipLine))
		{
			FIS_TipLine.SetBrushFromTexture(LineTex, true);
			FIS_SetTipLineBrush(FIS_TipLine.Brush);
		}
	}

	/** Divider line with the game's title-line picture, at the picture's own height. */
	void FIS_SetTipLineBrush(FSlateBrush LineBrush)
	{
		FIS_TipLine.SetBrush(LineBrush);
		FIS_TipLine.SetColorAndOpacity(FLinearColor(1.0, 1.0, 1.0, 1.0));
		float64 H = LineBrush.ImageSize.Y;
		FIS_TipLineH = (H >= 1.0 && H <= 40.0) ? H : 4.0;
	}

	/** Gives the tooltip the game's fonts: the big title font of the screen and the item-count font. */
	void FIS_TipTakeFonts()
	{
		if (FIS_bTipFonts || !IsValid(FIS_CountText) || !IsValid(FIS_TipTitleText) || !IsValid(FIS_TipActionText))
			return;
		FSlateFontInfo BodyFont = FIS_CountText.GetFont();
		float64 BodySize = BodyFont.Size;

		// Title font: the biggest font used on the inventory screen (the tab title, e.g. "ALL").
		FSlateFontInfo TitleFont = BodyFont;
		float64 Biggest = -1.0;
		TArray<UWidget> All;
		FIS_Collect(FIS_Base.GetRootWidget(), All, 0);
		for (int i = 0; i < All.Num(); i++)
		{
			UTextBlock T = Cast<UTextBlock>(All[i]);
			if (!IsValid(T) || T.GetName().ToString().StartsWith("FIS_"))
				continue;
			FSlateFontInfo F = T.GetFont();
			if (F.Size > Biggest)
			{
				Biggest = F.Size;
				TitleFont = F;
			}
		}
		TitleFont.Size = float32(BodySize * FIS_TipTitleScale);
		FIS_TipTitleText.SetFont(TitleFont);
		FIS_TipActionText.SetFont(BodyFont);
		for (int i = 0; i < FIS_TipOptionTexts.Num(); i++)
		{
			if (IsValid(FIS_TipOptionTexts[i]))
				FIS_TipOptionTexts[i].SetFont(BodyFont);
		}
		if (IsValid(FIS_TipApplyText))
			FIS_TipApplyText.SetFont(BodyFont);
		FIS_bTipFonts = true;
	}

	/** Lays the tooltip out from the size of its texts (in the canvas' own units). */
	void FIS_TipLayout()
	{
		// Menu: "SORT BY:", the entries and Apply. Tooltip: title + right-click hint.
		bool bMenu = FIS_bMenuOpen;
		FIS_TipTitleText.SetText(FText::FromString(bMenu ? FIS_MenuTitle : FIS_TipTitle));
		ESlateVisibility HintVis = bMenu ? ESlateVisibility::Collapsed : ESlateVisibility::HitTestInvisible;
		ESlateVisibility MenuVis = bMenu ? ESlateVisibility::HitTestInvisible : ESlateVisibility::Collapsed;
		ESlateVisibility AreaVis = bMenu ? ESlateVisibility::Visible : ESlateVisibility::Collapsed;
		FIS_TipActionText.SetVisibility(HintVis);
		if (IsValid(FIS_TipMouse))
			FIS_TipMouse.SetVisibility(HintVis);
		FIS_TipTitleText.ForceLayoutPrepass();
		FIS_TipActionText.ForceLayoutPrepass();
		FVector2D TitleSz = FIS_TipTitleText.GetDesiredSize();
		FVector2D ActionSz = FIS_TipActionText.GetDesiredSize();

		float64 Pad = 22.0;
		float64 Gap = 12.0;
		float64 MouseS = ActionSz.Y * 1.35;
		float64 RowW = MouseS + 10.0 + ActionSz.X;
		float64 Width = Math::Max(TitleSz.X, bMenu ? 0.0 : RowW) + Pad * 2.0;
		if (Width < 280.0)
			Width = 280.0;
		float64 LineY = Pad + TitleSz.Y + Gap;
		float64 RowY = LineY + FIS_TipLineH + Gap;

		// Menu entries: diamond in front of the chosen one, text, click area over the whole line.
		float64 MarkS = ActionSz.Y * 0.75;
		float64 TextX = Pad * 1.0 + MarkS + 10.0;
		float64 OptY = RowY;
		FIS_TipOptionH = ActionSz.Y * 1.45;
		FIS_TipOptionTops.Empty();
		for (int i = 0; i < FIS_TipOptionTexts.Num(); i++)
		{
			UTextBlock Opt = FIS_TipOptionTexts[i];
			if (IsValid(Opt))
			{
				Opt.SetVisibility(MenuVis);
				if (bMenu)
				{
					Opt.ForceLayoutPrepass();
					FVector2D OptSz = Opt.GetDesiredSize();
					if (TextX + OptSz.X + Pad * 1.3 > Width)
						Width = TextX + OptSz.X + Pad * 1.3;
					FIS_SetChildPos(Opt, FVector2D(TextX, OptY + (FIS_TipOptionH - OptSz.Y) * 0.5));
				}
			}
			FIS_TipOptionTops.Add(OptY);
			if (bMenu)
				OptY += FIS_TipOptionH;
		}

		// Apply button under the entries.
		float64 ApplyH = ActionSz.Y * 1.7;
		float64 ApplyW = ActionSz.Y * 6.0;
		if (IsValid(FIS_TipApplyText))
		{
			FIS_TipApplyText.SetVisibility(MenuVis);
			if (bMenu)
			{
				FIS_TipApplyText.ForceLayoutPrepass();
				ApplyW = Math::Max(ApplyW, FIS_TipApplyText.GetDesiredSize().X + Pad * 2.0);
			}
		}
		float64 ApplyY = OptY + Gap * 0.8;

		float64 RowH = Math::Max(MouseS, ActionSz.Y);
		float64 Height = RowY + RowH + Pad * 0.8;
		if (bMenu)
			Height = ApplyY + ApplyH + Pad * 0.9;
		FIS_TipSize = FVector2D(Width, Height);

		// Place the menu parts now that the width is known.
		for (int i = 0; i < FIS_TipOptionTexts.Num(); i++)
		{
			float64 Top = FIS_TipOptionTops[i];
			if (i < FIS_TipOptionMarks.Num() && IsValid(FIS_TipOptionMarks[i]))
				FIS_SetChildRect(FIS_TipOptionMarks[i], FVector2D(Pad * 1.0, Top + (FIS_TipOptionH - MarkS) * 0.5), FVector2D(MarkS, MarkS));
			if (i < FIS_TipOptionAreas.Num() && IsValid(FIS_TipOptionAreas[i]))
			{
				FIS_TipOptionAreas[i].SetVisibility(AreaVis);
				FIS_SetChildRect(FIS_TipOptionAreas[i], FVector2D(Pad * 0.6, Top), FVector2D(Width - Pad * 1.2, FIS_TipOptionH));
			}
		}
		FIS_TipApplySize = FVector2D(ApplyW, ApplyH);
		FIS_TipApplyPos = FVector2D((Width - ApplyW) * 0.5, ApplyY);
		if (IsValid(FIS_TipApplyFrame))
		{
			FIS_TipApplyFrame.SetVisibility(MenuVis);
			FIS_SetChildRect(FIS_TipApplyFrame, FIS_TipApplyPos, FIS_TipApplySize);
		}
		if (IsValid(FIS_TipApplyText) && bMenu)
		{
			FVector2D ApplySz = FIS_TipApplyText.GetDesiredSize();
			FIS_SetChildPos(FIS_TipApplyText, FIS_TipApplyPos + (FIS_TipApplySize - ApplySz) * 0.5);
		}
		if (IsValid(FIS_TipApplyArea))
		{
			FIS_TipApplyArea.SetVisibility(AreaVis);
			FIS_SetChildRect(FIS_TipApplyArea, FIS_TipApplyPos, FIS_TipApplySize);
		}

		FIS_SetChildRect(FIS_TipBg, FVector2D(0.0, 0.0), FIS_TipSize);
		FIS_SetChildRect(FIS_TipOutline, FVector2D(0.0, 0.0), FIS_TipSize);
		FIS_SetChildPos(FIS_TipTitleText, FVector2D((Width - TitleSz.X) * 0.5, Pad));
		FIS_SetChildRect(FIS_TipLine, FVector2D(Pad * 0.8, LineY), FVector2D(Width - Pad * 1.6, FIS_TipLineH));
		float64 RowX = (Width - RowW) * 0.5;
		FIS_SetChildRect(FIS_TipMouse, FVector2D(RowX, RowY + (RowH - MouseS) * 0.5), FVector2D(MouseS, MouseS));
		FIS_SetChildPos(FIS_TipActionText, FVector2D(RowX + MouseS + 10.0, RowY + (RowH - ActionSz.Y) * 0.5));

		// The panel takes clicks only where the menu's click areas are.
		FIS_Tip.SetVisibility(bMenu ? ESlateVisibility::SelfHitTestInvisible : ESlateVisibility::HitTestInvisible);

		UCanvasPanelSlot TipSlot = Cast<UCanvasPanelSlot>(FIS_Tip.Slot);
		if (IsValid(TipSlot))
			TipSlot.SetSize(FIS_TipSize);
		FIS_UpdateMenuLook(FVector2D(-1.0, -1.0));
	}

	/** Chosen entry: diamond + light text. Hovered entry / Apply: brighter. Inactive: dimmed. */
	void FIS_UpdateMenuLook(FVector2D LocalMouse)
	{
		if (!FIS_bMenuOpen)
			return;
		FVector2D InTip = LocalMouse - FIS_TipPos;
		for (int i = 0; i < FIS_TipOptionTexts.Num(); i++)
		{
			UTextBlock Opt = FIS_TipOptionTexts[i];
			if (!IsValid(Opt))
				continue;
			bool bActive = i < FIS_MenuOptionActive.Num() && FIS_MenuOptionActive[i];
			bool bChosen = bActive && (i == FIS_ModeStack ? FIS_PendingStack : i == FIS_PendingMode);
			bool bHover = bActive && i < FIS_TipOptionTops.Num()
				&& InTip.Y >= FIS_TipOptionTops[i] && InTip.Y < FIS_TipOptionTops[i] + FIS_TipOptionH
				&& InTip.X >= 0.0 && InTip.X <= FIS_TipSize.X;
			FLinearColor C = FIS_MenuOptionColor;
			if (bChosen || bHover)
				C = FLinearColor(0.84, 0.75, 0.70, 1.0);   // light, like the title
			if (!bActive)
				C = FLinearColor(C.R, C.G, C.B, 0.45);
			FSlateColor OptColor;
			OptColor.SpecifiedColor = C;
			Opt.SetColorAndOpacity(OptColor);
			if (i < FIS_TipOptionMarks.Num() && IsValid(FIS_TipOptionMarks[i]))
			{
				UImage Mark = FIS_TipOptionMarks[i];
				Mark.SetVisibility(bChosen ? ESlateVisibility::HitTestInvisible : ESlateVisibility::Collapsed);
				// "Stack all items" switched on (applied) in this save: gold diamond.
				bool bStackLive = i == FIS_ModeStack && bChosen && FIST_IsStackingOn();
				Mark.SetColorAndOpacity(bStackLive ? FIS_StackOnMarkColor : FLinearColor(1.0, 1.0, 1.0, 1.0));
			}
		}
		if (IsValid(FIS_TipApplyFrame))
		{
			bool bOverApply = InTip.X >= FIS_TipApplyPos.X && InTip.X <= FIS_TipApplyPos.X + FIS_TipApplySize.X
				&& InTip.Y >= FIS_TipApplyPos.Y && InTip.Y <= FIS_TipApplyPos.Y + FIS_TipApplySize.Y;
			FIS_TipApplyFrame.SetColorAndOpacity(bOverApply ? FLinearColor(1.0, 1.0, 1.0, 1.0) : FLinearColor(0.78, 0.78, 0.78, 1.0));
		}
	}

	/** Click in the menu: choose an entry, or Apply (-1) = remember it and close the menu. */
	void FIS_OnMenuItem(int Index)
	{
		if (Index == -1)
		{
			if (IsValid(FIS_Settings))
			{
				FIS_Settings.SortMode = FIS_PendingMode;
				FIS_SaveSettings();
			}
			FIST_SetStacking(FIS_PendingStack);   // per save game (part 3)
			FIS_PlayClickSound();
			FIS_bMenuOpen = false;
			FIS_bTipDirty = true;
			FIS_LastAction = f"sort mode {FIS_PendingMode} applied, stacking {FIS_PendingStack}";
			return;
		}
		if (Index < 0 || Index >= FIS_MenuOptionActive.Num() || !FIS_MenuOptionActive[Index])
			return;
		if (Index == FIS_ModeStack)
			FIS_PendingStack = !FIS_PendingStack;   // on/off, independent of the sort mode
		else
			FIS_PendingMode = Index;
		FIS_PlayClickSound();
		FIS_UpdateMenuLook(FVector2D(-1.0, -1.0));
	}

	void FIS_SetChildRect(UWidget W, FVector2D Pos, FVector2D Sz)
	{
		if (!IsValid(W))
			return;
		UCanvasPanelSlot WSlot = Cast<UCanvasPanelSlot>(W.Slot);
		if (!IsValid(WSlot))
			return;
		WSlot.SetAutoSize(false);
		WSlot.SetPosition(Pos);
		WSlot.SetSize(Sz);
	}

	void FIS_SetChildPos(UWidget W, FVector2D Pos)
	{
		if (!IsValid(W))
			return;
		UCanvasPanelSlot WSlot = Cast<UCanvasPanelSlot>(W.Slot);
		if (IsValid(WSlot))
			WSlot.SetPosition(Pos);
	}

	/** Shows the tooltip after resting on the Sort button, to the right of the inventory panel. */
	void FIS_UpdateTooltip(int64 NowTicks, FVector2D Mouse)
	{
		if (!IsValid(FIS_Tip))
			return;
		bool bHovering = FIS_bShown && FIS_bHover && !FIS_bBarDragging;
		if (!bHovering)
			FIS_HoverSince = 0;
		else if (FIS_HoverSince == 0)
			FIS_HoverSince = NowTicks;
		bool bWant = bHovering && float64(NowTicks - FIS_HoverSince) / 10000000.0 >= FIS_TipDelay;

		// Click catcher: only while the menu is open.
		if (IsValid(FIS_Catcher))
		{
			ESlateVisibility CatchVis = (FIS_bMenuOpen && FIS_bShown) ? ESlateVisibility::Visible : ESlateVisibility::Collapsed;
			if (FIS_Catcher.GetVisibility() != CatchVis)
				FIS_Catcher.SetVisibility(CatchVis);
		}

		// The right-click menu stays open until the Sort button is right-clicked again, a click
		// lands outside it, or the button goes away (inventory closed, other tab).
		if (FIS_bMenuOpen)
		{
			if (FIS_bShown)
				bWant = true;
			else
			{
				FIS_bMenuOpen = false;
				FIS_bTipDirty = true;
			}
		}

		if (!bWant)
		{
			if (FIS_bTipShown)
			{
				FIS_Tip.SetVisibility(ESlateVisibility::Collapsed);
				FIS_bTipShown = false;
			}
			return;
		}

		if (!FIS_bTipShown)
		{
			FIS_TipTakeFonts();
			FIS_TipApplyGameStyle();
			FIS_Tip.SetVisibility(ESlateVisibility::HitTestInvisible);   // FIS_TipLayout sets the final value
			FIS_TipLayout();
			FIS_bTipShown = true;
			FIS_bTipDirty = false;
		}
		else if (FIS_bTipDirty)
		{
			FIS_TipLayout();
			FIS_bTipDirty = false;
		}

		// Place: left edge a little right of the inventory panel, bottom level with the button.
		FGeometry GridGeo = FIS_Grid.GetCachedGeometry();
		FVector2D GridLocal = GridGeo.GetLocalSize();
		if (GridLocal.X <= 0.0)
			return;
		FVector2D GridTL = GridGeo.LocalToAbsolute(FVector2D(0.0, 0.0));
		FVector2D GridBR = GridGeo.LocalToAbsolute(GridLocal);
		float64 TileW = FIS_Grid.m_ItemWidth * (GridBR.X - GridTL.X) / GridLocal.X;
		FVector2D AbsAnchor = FVector2D(GridBR.X + TileW * 0.9, FIS_BtnAbsPos.Y + FIS_BtnAbsSize.Y);

		FGeometry CanvasGeo = FIS_Canvas.GetCachedGeometry();
		FVector2D Local = CanvasGeo.AbsoluteToLocal(AbsAnchor);
		float64 TipTop = Local.Y - FIS_TipSize.Y;
		if (TipTop < 10.0)
			TipTop = 10.0;
		FIS_TipPos = FVector2D(Local.X, TipTop);
		FIS_Tip.SetRenderTranslation(FIS_TipPos);
		if (FIS_bMenuOpen)
			FIS_UpdateMenuLook(CanvasGeo.AbsoluteToLocal(Mouse));
	}

	/** Plays the game's button click sound (loaded once). */
	void FIS_PlayClickSound()
	{
		if (!FIS_bClickSoundTried)
		{
			FIS_bClickSoundTried = true;
			FIS_ClickSound = Cast<UFMODEvent>(LoadObject(nullptr, FIS_ClickSoundPath));
		}
		if (IsValid(FIS_ClickSound))
			FMODBlueprint::PlayEvent2D(this, FIS_ClickSound, true);
	}

	/** Right click: (only without the drag mod) stop keeping the list sorted, game order back. */
	void FIS_OnRightClick()
	{
		// Combined mod: right click opens / closes the sort menu in the tooltip panel.
		if (FIS_ShowTooltip && IsValid(FIS_Tip))
		{
			FIS_bMenuOpen = !FIS_bMenuOpen;
			if (FIS_bMenuOpen)
			{
				FIS_PendingMode = FIS_ActiveMode();
				FIS_PendingStack = FIST_IsStackingOn();
			}
			FIS_bTipDirty = true;
			FIS_PlayClickSound();
			FIS_LastAction = FIS_bMenuOpen ? "sort menu opened" : "sort menu closed";
			return;
		}
		if (FIS_bDragMod)
		{
			FIS_LastAction = "right click: nothing to do (the drag mod keeps the order)";
			return;
		}
		if (IsValid(FIS_Settings))
		{
			FIS_Settings.bAutoSort = false;
			FIS_SaveSettings();
		}
		FIS_LastApplied.Empty();
		if (IsValid(FIS_Inv))
			FIS_Inv.RefreshInventory(true);
		FIS_LastAction = "auto sort off, game order back";
	}

	// ------------------------------------------------------------------
	//  Sorting
	// ------------------------------------------------------------------

	void FIS_SortNow()
	{
		if (!IsValid(FIS_Grid))
			return;
		TArray<UObject> Items = FIS_Grid.GetListItems();
		TArray<UObject> Sorted = FIS_SortItems(Items);

		// Setting the list scrolls the grid to the top: keep the row you were looking at.
		int KeepOffset = FIS_Grid.GetCurrentScrollOffset();
		FIS_Grid.SetListItemsBP(Sorted, true);
		FIS_Grid.SetScrollOffset(KeepOffset);
		FIS_KeepScrollOffset = KeepOffset;
		FIS_KeepScrollFrames = 12;   // the grid may only rebuild a frame later
		FIS_LastApplied = Sorted;
		FIS_Sorts++;

		// Tell the item dragging part to take this order over (it listens to the grid's hover
		// event). Harmless when the drag mod is not there.
		FIS_Grid.m_OnItemIsHoveredChangedBP.Broadcast(FIS_SignalIndex, this, false);

		FIS_LastAction = f"sorted {Sorted.Num()} items ({FIS_LastUnmatched} without category), drag mod {FIS_bDragMod}";
	}

	/** Without the drag mod: keep the All tab sorted whenever the game refills the grid. */
	void FIS_KeepAutoSorted(int64 NowTicks)
	{
		if (FIS_bDragMod || FIS_AutoBlocked || !IsValid(FIS_Settings) || !FIS_Settings.bAutoSort)
			return;
		TArray<UObject> Items = FIS_Grid.GetListItems();
		if (FIS_SameList(Items, FIS_LastApplied))
			return;

		TArray<UObject> Sorted = FIS_SortItems(Items);
		if (!FIS_SameList(Sorted, Items))
		{
			// Safety: if something else keeps changing the order back, stop instead of fighting.
			FIS_AutoTimes.Add(NowTicks);
			while (FIS_AutoTimes.Num() > 0 && NowTicks - FIS_AutoTimes[0] > 20000000)
				FIS_AutoTimes.RemoveAt(0);
			if (FIS_AutoTimes.Num() > 8)
			{
				FIS_AutoBlocked = true;
				FIS_LastAction = "auto sort stopped: something else keeps reordering the grid";
				return;
			}

			int KeepOffset = FIS_Grid.GetCurrentScrollOffset();
			FIS_Grid.SetListItemsBP(Sorted, true);
			FIS_Grid.SetScrollOffset(KeepOffset);
			FIS_LastAction = f"kept sorted ({Sorted.Num()} items)";
		}
		FIS_LastApplied = Sorted;
	}

	// ==================================================================
	//  Sort modes. FIS_SortItems() picks the chosen one; each mode is its own function and they
	//  only share FIS_ReadItems() (what each grid item is) and FIS_Before() (category order).
	// ==================================================================

	TArray<UObject> FIS_SortItems(TArray<UObject> Items)
	{
		if (FIS_ActiveMode() == FIS_ModeValues)
			return FIS_SortByValues(Items);
		return FIS_SortByCategories(Items);
	}

	int FIS_ActiveMode()
	{
		if (!IsValid(FIS_Settings) || FIS_Settings.SortMode == FIS_ModeStack)
			return FIS_ModeCategories;
		return FIS_Settings.SortMode;
	}

	/**
	 * What every grid item is: category, matching tag, item type, name, value, hotbar order and
	 * its item definition (nullptr if unknown). One entry per item, same order as Items.
	 */
	void FIS_ReadItems(TArray<UObject> Items, TArray<int>& Cats, TArray<int>& Subs, TArray<FString>& Types,
		TArray<FString>& Names, TArray<int>& Values, TArray<FString>& Hotkeys, TArray<UItemDefinition>& Defs)
	{
		FIS_BuildCategoryMap();
		int Unknown = FIS_CatNames.Num();
		FIS_LastUnmatched = 0;
		FIS_LastFullMatches = 0;
		FIS_UnmatchedNames = "";
		FIS_LastHotbar = "";

		for (int i = 0; i < Items.Num(); i++)
		{
			FString HotOrder = "";
			int Cat = 1000;
			int Sub = 0;
			FString TypeText = "";
			FString ItemName = "";
			int ItemValue = 0;
			UItemDefinition Def = nullptr;
			UInventorySlotData Data = Cast<UInventorySlotData>(Items[i]);
			if (IsValid(Data) && !Data.m_IsEmpty)
			{
				ItemName = Data.m_Name.ToString();
				ItemValue = Data.m_Value;
				HotOrder = FIS_HotbarOrder(Data.m_Hotkey);
				// "name|value" first: a rune and a scroll of the same spell share their name.
				FString FullKey = f"{ItemName}|{ItemValue}";
				FString LookKey = ItemName;
				if (FIS_CatByName.Contains(FullKey))
				{
					LookKey = FullKey;
					FIS_LastFullMatches++;
				}
				if (!ItemName.IsEmpty() && FIS_CatByName.Find(LookKey, Cat))
				{
					if (!FIS_SubByName.Find(LookKey, Sub))
						Sub = 0;
					if (!FIS_TypeByName.Find(LookKey, TypeText))
						TypeText = "";
					if (!FIS_DefByName.Find(LookKey, Def))
						Def = nullptr;
				}
				else
				{
					Cat = Unknown;
					FIS_LastUnmatched++;
					if (FIS_LastUnmatched <= 6)
						FIS_UnmatchedNames += f"{ItemName}, ";
				}
			}
			// Wearables (armour, rings, amulets) cannot be on the hotbar: their number square only
			// means "worn", so they stay in their category.
			if (Cat == FIS_WearablesCat)
				HotOrder = "";
			if (!HotOrder.IsEmpty())
				FIS_LastHotbar += f"{HotOrder}={ItemName}, ";

			Cats.Add(Cat);
			Subs.Add(Sub);
			Types.Add(TypeText);
			Names.Add(ItemName);
			Values.Add(ItemValue);
			Hotkeys.Add(HotOrder);
			Defs.Add(Def);
		}
	}

	/** Stable insertion sort result: the items in the order of the index list. */
	TArray<UObject> FIS_Reorder(TArray<UObject> Items, TArray<int> Order)
	{
		TArray<UObject> Sorted;
		for (int i = 0; i < Order.Num(); i++)
			Sorted.Add(Items[Order[i]]);
		return Sorted;
	}

	// ------------------------------------------------------------------
	//  Mode 1: Categories
	//  Hotbar items first (1-9, 0), then the category tabs in order; inside a category the
	//  matching tag, then the kind of item (e.g. one-handed swords), ranked by value high-low.
	// ------------------------------------------------------------------

	TArray<UObject> FIS_SortByCategories(TArray<UObject> Items)
	{
		TArray<int> Cats;
		TArray<int> Subs;
		TArray<FString> Types;
		TArray<FString> Names;
		TArray<int> Values;
		TArray<FString> Hotkeys;
		TArray<UItemDefinition> Defs;
		FIS_ReadItems(Items, Cats, Subs, Types, Names, Values, Hotkeys, Defs);
		TArray<FString> Kinds = FIS_TagPrefixes(Types, 4);

		TArray<int> Order;
		for (int i = 0; i < Items.Num(); i++)
			Order.Add(i);
		for (int i = 1; i < Order.Num(); i++)
		{
			int Cur = Order[i];
			int j = i - 1;
			while (j >= 0 && FIS_Before(Cur, Order[j], Hotkeys, Cats, Subs, Kinds, Names, Values))
			{
				Order[j + 1] = Order[j];
				j--;
			}
			Order[j + 1] = Cur;
		}
		return FIS_Reorder(Items, Order);
	}

	// ------------------------------------------------------------------
	//  Mode 2: Values
	//  Items that make the hero stronger, best first, in these groups:
	//   weapons (damage) - armour (protection + bonuses) - rings - amulets (sum of bonuses) -
	//   healing drinks - mana drinks - permanent potions - food - herbs (instant before per second,
	//   healing before mana). Hotbar items stay first (like in every mode). Inside a group one family after
	//   the other (swords, axes, maces ... crossbows, bows), each ranked best first. Everything
	//   else comes after them, sorted like Categories.
	// ------------------------------------------------------------------

	TArray<UObject> FIS_SortByValues(TArray<UObject> Items)
	{
		TArray<int> Cats;
		TArray<int> Subs;
		TArray<FString> Types;
		TArray<FString> Names;
		TArray<int> Values;
		TArray<FString> Hotkeys;
		TArray<UItemDefinition> Defs;
		FIS_ReadItems(Items, Cats, Subs, Types, Names, Values, Hotkeys, Defs);

		TArray<FString> Kinds = FIS_TagPrefixes(Types, 4);      // e.g. Item.Weapon.Sword.OneHand
		TArray<FString> Families = FIS_TagPrefixes(Types, 3);   // e.g. Item.Weapon.Sword
		TArray<int> FamilyRanks;
		for (int i = 0; i < Families.Num(); i++)
			FamilyRanks.Add(FIS_FamilyRank(Families[i]));

		UAbilitySystemComponent PlayerAsc = FIS_PlayerAbilitySystem();
		TArray<int> Groups;
		TArray<float64> Scores;
		TArray<float64> Scores2;
		int Scored = 0;
		for (int i = 0; i < Items.Num(); i++)
		{
			int Group = FIS_GroupRest;
			float64 Score = 0.0;
			float64 Score2 = 0.0;
			if (IsValid(Defs[i]))
				FIS_ValueOf(Defs[i], Cats[i], PlayerAsc, Group, Score, Score2);
			if (Group != FIS_GroupRest)
				Scored++;
			Groups.Add(Group);
			Scores.Add(Score);
			Scores2.Add(Score2);
		}
		FIS_ValuesInfo = f"{Scored} items rated, ability system {IsValid(PlayerAsc)}";

		TArray<int> Order;
		for (int i = 0; i < Items.Num(); i++)
			Order.Add(i);
		for (int i = 1; i < Order.Num(); i++)
		{
			int Cur = Order[i];
			int j = i - 1;
			while (j >= 0 && FIS_BeforeByValue(Cur, Order[j], Groups, Scores, Scores2, FamilyRanks, Families, Hotkeys, Cats, Subs, Kinds, Names, Values))
			{
				Order[j + 1] = Order[j];
				j--;
			}
			Order[j + 1] = Cur;
		}
		return FIS_Reorder(Items, Order);
	}

	bool FIS_BeforeByValue(int A, int B, TArray<int>& Groups, TArray<float64>& Scores, TArray<float64>& Scores2,
		TArray<int>& FamilyRanks, TArray<FString>& Families, TArray<FString>& Hotkeys, TArray<int>& Cats, TArray<int>& Subs,
		TArray<FString>& Kinds, TArray<FString>& Names, TArray<int>& Values)
	{
		// Hotbar items first, in hotbar order (same as in every mode).
		bool bHotA = !Hotkeys[A].IsEmpty();
		bool bHotB = !Hotkeys[B].IsEmpty();
		if (bHotA != bHotB)
			return bHotA;
		if (bHotA)
			return Hotkeys[A].Compare(Hotkeys[B], ESearchCase::IgnoreCase) < 0;

		if (Groups[A] != Groups[B])
			return Groups[A] < Groups[B];
		if (Groups[A] == FIS_GroupRest)
			return FIS_Before(A, B, Hotkeys, Cats, Subs, Kinds, Names, Values);

		// Inside a group: one family after the other (swords, axes ... crossbows, bows) ...
		if (FamilyRanks[A] != FamilyRanks[B])
			return FamilyRanks[A] < FamilyRanks[B];
		int FamilyCmp = Families[A].Compare(Families[B], ESearchCase::IgnoreCase);
		if (FamilyCmp != 0)
			return FamilyCmp < 0;
		// ... and inside a family rank by rank, best first.
		if (Scores[A] != Scores[B])
			return Scores[A] > Scores[B];
		if (Scores2[A] != Scores2[B])
			return Scores2[A] > Scores2[B];
		int NameCmp = Names[A].Compare(Names[B], ESearchCase::IgnoreCase);
		if (NameCmp != 0)
			return NameCmp < 0;
		return Values[A] > Values[B];
	}

	/** Which Values group an item belongs to and how good it is (higher = better). */
	void FIS_ValueOf(UItemDefinition Def, int Cat, UAbilitySystemComponent PlayerAsc, int& Group, float64& Score, float64& Score2)
	{
		Group = FIS_GroupRest;
		Score = 0.0;
		Score2 = 0.0;

		// Weapons (melee and ranged; not ammo, torches, runes or scrolls): total damage.
		UWeaponDefinition Weapon = Cast<UWeaponDefinition>(Def);
		if (IsValid(Weapon) && (Cat == 0 || Cat == 1)
			&& !Def.MatchesItemType(GameplayTag::Item_Ammo)
			&& !Def.MatchesItemType(GameplayTag::Item_Projectile_Arrow)
			&& !Def.MatchesItemType(GameplayTag::Item_Projectile_Bolt))
		{
			float64 Damage = 0.0;
			TArray<FGameplayTag> DamageTypes = Weapon.GetDamageTypes();
			for (int t = 0; t < DamageTypes.Num(); t++)
				Damage += Weapon.GetDamage(DamageTypes[t]);
			Group = FIS_GroupWeapon;
			Score = Damage;
			return;
		}

		// Armour: all protections plus all bonuses.
		UArmorDefinition Armor = Cast<UArmorDefinition>(Def);
		if (IsValid(Armor))
		{
			Group = FIS_GroupArmor;
			Score = float64(Armor.GetEdgeProtection() + Armor.GetBluntProtection() + Armor.GetPointProtection()
				+ Armor.GetFireProtection() + Armor.GetWindProtection() + Armor.GetIceProtection() + Armor.GetEnergyProtection()
				+ Armor.GetBuffEdgeProtection() + Armor.GetBuffBluntProtection() + Armor.GetBuffPointProtection()
				+ Armor.GetBuffFireProtection() + Armor.GetBuffWindProtection() + Armor.GetBuffIceProtection() + Armor.GetBuffEnergyProtection()
				+ Armor.GetBuffStrength() + Armor.GetBuffDexterity() + Armor.GetBuffHealth() + Armor.GetBuffMana() + Armor.GetBuffToughness());
			return;
		}

		// Rings and amulets: sum of the bonuses of their equip effect (as the tooltip shows them).
		bool bRing = Def.MatchesItemType(GameplayTag::Item_Ring);
		bool bAmulet = Def.MatchesItemType(GameplayTag::Item_Amulet);
		if (bRing || bAmulet)
		{
			Group = bRing ? FIS_GroupRing : FIS_GroupAmulet;
			Score = FIS_EquipBonusSum(Def, PlayerAsc);
			Score2 = float64(Def.m_Value);
			return;
		}

		// Consumables: what their effects give.
		float64 HealInstant = 0.0;
		float64 HealPerSec = 0.0;
		float64 HealSecs = 0.0;
		float64 ManaInstant = 0.0;
		float64 ManaPerSec = 0.0;
		float64 ManaSecs = 0.0;
		float64 StatBonus = 0.0;
		for (int e = 0; e < Def.m_OnConsumeEffects.Num(); e++)
		{
			UItemEffectDefinition Effect = Def.m_OnConsumeEffects[e];
			if (!IsValid(Effect))
				continue;
			UClass EffectClass = Effect.m_Effect.Get();
			FString EffectName = IsValid(EffectClass) ? EffectClass.GetName().ToString() : "";
			float64 Heal = FIS_Magnitude(Effect, GameplayTag::GE_Param_Heal);
			float64 Mana = FIS_Magnitude(Effect, GameplayTag::GE_Param_Mana);
			float64 Secs = FIS_Magnitude(Effect, GameplayTag::GE_Param_Duration);
			bool bOverTime = EffectName.Contains("Overtime");
			if (EffectName.Contains("MaxHeal") || EffectName.Contains("MaxMana"))
			{
				StatBonus += FIS_Magnitude(Effect, GameplayTag::GE_Param_MaxHeal) + FIS_Magnitude(Effect, GameplayTag::GE_Param_MaxMana);
			}
			else if (EffectName.Contains("Strength") || EffectName.Contains("Dexterity"))
			{
				StatBonus += FIS_Magnitude(Effect, GameplayTag::GE_Param_Strength) + FIS_Magnitude(Effect, GameplayTag::GE_Param_Dexterity);
			}
			else if (Heal > 0.0)
			{
				if (bOverTime)
				{
					HealPerSec += Heal;
					HealSecs = Math::Max(HealSecs, Secs);
				}
				else
					HealInstant += Heal;
			}
			else if (Mana > 0.0)
			{
				if (bOverTime)
				{
					ManaPerSec += Mana;
					ManaSecs = Math::Max(ManaSecs, Secs);
				}
				else
					ManaInstant += Mana;
			}
		}

		// Drinks first (healing, then mana), then permanent potions, then food, then herbs.
		bool bHeal = HealInstant > 0.0 || HealPerSec > 0.0;
		bool bMana = ManaInstant > 0.0 || ManaPerSec > 0.0;
		bool bFood = Def.MatchesItemType(GameplayTag::Item_Food);
		bool bHerb = Def.MatchesItemType(GameplayTag::Item_Herb) || Def.MatchesItemType(GameplayTag::Item_Drug);
		bool bDrink = !bFood && !bHerb;   // potions and other drinks

		if (bDrink && HealInstant > 0.0)
		{
			Group = FIS_GroupHealDrink;
			Score = HealInstant;
		}
		else if (bDrink && HealPerSec > 0.0)
		{
			Group = FIS_GroupHealDrinkSlow;
			Score = HealPerSec;              // fastest healing first ...
			Score2 = HealPerSec * HealSecs;  // ... then the most healing in total
		}
		else if (bDrink && ManaInstant > 0.0)
		{
			Group = FIS_GroupManaDrink;
			Score = ManaInstant;
		}
		else if (bDrink && ManaPerSec > 0.0)
		{
			Group = FIS_GroupManaDrinkSlow;
			Score = ManaPerSec;
			Score2 = ManaPerSec * ManaSecs;
		}
		else if (StatBonus > 0.0)
		{
			Group = FIS_GroupStatPotion;
			Score = StatBonus;
		}
		else if (bHeal || bMana)
		{
			// Food / herbs: instant amounts count like 10 seconds of healing per second.
			if (bHeal)
			{
				Group = bHerb ? FIS_GroupHerbHeal : FIS_GroupFoodHeal;
				Score = HealPerSec + HealInstant * 0.1;
				Score2 = HealPerSec * HealSecs + HealInstant;
			}
			else
			{
				Group = bHerb ? FIS_GroupHerbMana : FIS_GroupFoodMana;
				Score = ManaPerSec + ManaInstant * 0.1;
				Score2 = ManaPerSec * ManaSecs + ManaInstant;
			}
		}
	}

	float64 FIS_Magnitude(UItemEffectDefinition Effect, FGameplayTag Tag)
	{
		float32 Mag = 0.0;
		if (Effect.m_Magnitudes.Find(Tag, Mag))
			return Mag;
		return 0.0;
	}

	/** Sum of all attribute bonuses of an item's equip effect (rings, amulets). */
	float64 FIS_EquipBonusSum(UItemDefinition Def, UAbilitySystemComponent PlayerAsc)
	{
		if (!IsValid(PlayerAsc) || !IsValid(Def.m_OnEquipEffect.Get()))
			return 0.0;
		// The game's helper takes a list of its script gameplay effects.
		TSubclassOf<UScriptGameplayEffect> EquipEffect = Def.m_OnEquipEffect.Get();
		if (!IsValid(EquipEffect.Get()))
			return 0.0;
		TArray<TSubclassOf<UScriptGameplayEffect>> Effects;
		Effects.Add(EquipEffect);
		TMap<FGameplayAttribute, float32> Bonuses = UItemDefinition::GetAttributeListFromGEList(PlayerAsc, Effects);
		float64 Sum = 0.0;
		for (auto Bonus : Bonuses)
			Sum += Bonus.Value;
		return Sum;
	}

	UAbilitySystemComponent FIS_PlayerAbilitySystem()
	{
		AActor PlayerActor = Gameplay::GetPlayerCharacter(0);
		UAbilitySystemComponent Asc = IsValid(PlayerActor) ? AbilitySystem::GetAbilitySystemComponent(PlayerActor) : nullptr;
		if (!IsValid(Asc))
		{
			APlayerState PlayerState = Gameplay::GetPlayerState(0);
			if (IsValid(PlayerState))
				Asc = AbilitySystem::GetAbilitySystemComponent(PlayerState);
		}
		return Asc;
	}

	/** Sort text for a hotbar key: "1".."9" -> "01".."09", "0" -> "10", other keys after them, "" = none. */
	FString FIS_HotbarOrder(FString Hotkey)
	{
		FString Key = Hotkey.TrimStartAndEnd();
		if (Key.IsEmpty())
			return "";
		if (Key == "0")
			return "10";
		if (Key.Len() == 1 && Key.IsNumeric())
			return "0" + Key;
		return "z" + Key;
	}

	/** True if item A must come before item B. */
	bool FIS_Before(int A, int B, TArray<FString>& Hotkeys, TArray<int>& Cats, TArray<int>& Subs, TArray<FString>& Types, TArray<FString>& Names, TArray<int>& Values)
	{
		// Hotbar items first, in hotbar order.
		bool bHotA = !Hotkeys[A].IsEmpty();
		bool bHotB = !Hotkeys[B].IsEmpty();
		if (bHotA != bHotB)
			return bHotA;
		if (bHotA)
		{
			int HotCmp = Hotkeys[A].Compare(Hotkeys[B], ESearchCase::IgnoreCase);
			if (HotCmp != 0)
				return HotCmp < 0;
		}
		if (Cats[A] != Cats[B])
			return Cats[A] < Cats[B];
		if (Subs[A] != Subs[B])
			return Subs[A] < Subs[B];
		// Same kind of item together (Types = item type cut to 4 parts, e.g. Item.Weapon.Sword.OneHand),
		// then rank by rank: most valuable first, then A-Z.
		int TypeCmp = Types[A].Compare(Types[B], ESearchCase::IgnoreCase);
		if (TypeCmp != 0)
			return TypeCmp < 0;
		if (Values[A] != Values[B])
			return Values[A] > Values[B];
		return Names[A].Compare(Names[B], ESearchCase::IgnoreCase) < 0;
	}

	/** First parts of a tag text: FIS_TagPrefix("Item.Weapon.Sword.OneHand", 3) = "Item.Weapon.Sword". */
	FString FIS_TagPrefix(FString Tag, int Parts)
	{
		int Pos = -1;
		for (int n = 0; n < Parts; n++)
		{
			int Next = Tag.Find(".", ESearchCase::CaseSensitive, ESearchDir::FromStart, Pos + 1);
			if (Next < 0)
				return Tag;
			Pos = Next;
		}
		return Tag.Left(Pos);
	}

	TArray<FString> FIS_TagPrefixes(TArray<FString> Tags, int Parts)
	{
		TArray<FString> Result;
		for (int i = 0; i < Tags.Num(); i++)
			Result.Add(FIS_TagPrefix(Tags[i], Parts));
		return Result;
	}

	/**
	 * Order of the item families inside a Values group: melee weapons (swords, axes, maces,
	 * staffs, orc weapons, fists), then crossbows, then bows; potions, food, herbs, drugs.
	 * Other families follow (A-Z).
	 */
	int FIS_FamilyRank(FString Family)
	{
		TArray<FString> Known;
		Known.Add(".Sword");
		Known.Add(".Axe");
		Known.Add(".Mace");
		Known.Add(".Staff");
		Known.Add(".Orc");
		Known.Add(".Fist");
		Known.Add(".Crossbow");
		Known.Add(".Bow");
		Known.Add(".Potion");
		Known.Add(".Food");
		Known.Add(".Herb");
		Known.Add(".Drug");
		for (int i = 0; i < Known.Num(); i++)
		{
			if (Family.EndsWith(Known[i]))
				return i;
		}
		return 100;
	}

	/** Item name -> category, from the player's inventory. */
	void FIS_BuildCategoryMap()
	{
		FIS_CatByName.Empty();
		FIS_SharedNames = 0;
		FIS_SubByName.Empty();
		FIS_TypeByName.Empty();
		FIS_DefByName.Empty();
		UInventoryComponent InvComp = nullptr;
		AActor PlayerActor = Gameplay::GetPlayerCharacter(0);
		if (!IsValid(PlayerActor))
			PlayerActor = Gameplay::GetPlayerPawn(0);
		AGothicCharacter GothicChar = Cast<AGothicCharacter>(PlayerActor);
		if (IsValid(GothicChar))
			InvComp = GothicChar.GetInventory();
		if (!IsValid(InvComp) && IsValid(PlayerActor))
			InvComp = UInventoryComponent::Get(PlayerActor);
		if (!IsValid(InvComp))
		{
			FString ActorInfo = IsValid(PlayerActor) ? PlayerActor.GetClass().GetName().ToString() : "no player actor";
			FIS_InvInfo = f"player inventory NOT found (player: {ActorInfo}, gothic character {IsValid(GothicChar)})";
			return;
		}

		int DefCount = 0;
		for (auto Def : InvComp.GetItems())
		{
			if (!IsValid(Def))
				continue;
			DefCount++;
			FString DefName = Def.m_Name.ToString();
			if (DefName.IsEmpty())
				continue;
			int TagIndex = FIS_TagIndexOf(Def);
			int Cat = TagIndex >= 0 ? FIS_TagCats[TagIndex] : FIS_CatNames.Num();
			int SubIndex = TagIndex >= 0 ? TagIndex : 0;
			FString TypeText = Def.GetItemType().ToString();

			// Exact entry "name|value" (always) ...
			FString FullKey = f"{DefName}|{Def.m_Value}";
			FIS_CatByName.Add(FullKey, Cat);
			FIS_SubByName.Add(FullKey, SubIndex);
			FIS_TypeByName.Add(FullKey, TypeText);
			FIS_DefByName.Add(FullKey, Def);
			if (!FIS_DefByName.Contains(DefName))
				FIS_DefByName.Add(DefName, Def);

			// ... and a name-only fallback (the most important category wins).
			FString OldType = "";
			if (FIS_TypeByName.Find(DefName, OldType) && OldType != TypeText)
				FIS_SharedNames++;
			int Old = -1;
			if (!FIS_CatByName.Find(DefName, Old) || Cat < Old)
			{
				FIS_CatByName.Add(DefName, Cat);
				FIS_SubByName.Add(DefName, SubIndex);
				FIS_TypeByName.Add(DefName, TypeText);
			}
		}
		FIS_InvInfo = f"{DefCount} item types in the player's inventory, {FIS_CatByName.Num()} names";
	}

	/** Index of the first category tag the item matches (-1 = none). */
	int FIS_TagIndexOf(UItemDefinition Def)
	{
		for (int t = 0; t < FIS_Tags.Num(); t++)
		{
			if (Def.MatchesItemType(FIS_Tags[t]) || Def.HasItemSpec(FIS_Tags[t]))
				return t;
		}
		return -1;
	}

	bool FIS_SameList(TArray<UObject> A, TArray<UObject> B)
	{
		if (A.Num() != B.Num())
			return false;
		for (int i = 0; i < A.Num(); i++)
		{
			if (A[i] != B[i])
				return false;
		}
		return true;
	}

	// ------------------------------------------------------------------
	//  Settings
	// ------------------------------------------------------------------

	void FIS_LoadSettings()
	{
		if (Gameplay::DoesSaveGameExist(FIS_SaveSlot, 0))
			FIS_Settings = Cast<UFIS_Settings>(Gameplay::LoadGameFromSlot(FIS_SaveSlot, 0));
		if (!IsValid(FIS_Settings))
			FIS_Settings = Cast<UFIS_Settings>(Gameplay::CreateSaveGameObject(UFIS_Settings));
	}

	void FIS_SaveSettings()
	{
		if (IsValid(FIS_Settings))
			Gameplay::SaveGameToSlot(FIS_Settings, FIS_SaveSlot, 0);
	}

	// ------------------------------------------------------------------
	//  Debug output
	// ------------------------------------------------------------------

	void FIS_UpdateDebugText(bool bAllTab, FVector2D Mouse)
	{
		if (!IsValid(FIS_DebugText))
			return;
		FString TabTag = IsValid(FIS_Filter) ? FIS_Filter.GetSelectedFilterTag().ToString() : "no filter widget";
		int ListCount = IsValid(FIS_Grid) ? FIS_Grid.GetNumItems() : -1;
		bool bAuto = IsValid(FIS_Settings) && FIS_Settings.bAutoSort;

		FString S = "InventorySorting debug";
		S += f"\ninventory {IsValid(FIS_Inv)}, grid {IsValid(FIS_Grid)} ({ListCount} items), filter {IsValid(FIS_Filter)}";
		S += f"\ntab: {TabTag}, All tab {bAllTab}";
		S += f"\nhost panel: {FIS_HostInfo}";
		S += f"\nicon: {FIS_IconInfo}";
		S += f"\ncount text: {FIS_CountInfo}";
		S += f"\nbutton shown {FIS_bShown} at ({Math::RoundToInt(FIS_BtnAbsPos.X)}, {Math::RoundToInt(FIS_BtnAbsPos.Y)}) size {Math::RoundToInt(FIS_BtnAbsSize.X)}x{Math::RoundToInt(FIS_BtnAbsSize.Y)}, hover {FIS_bHover}";
		S += f"\nmouse ({Math::RoundToInt(Mouse.X)}, {Math::RoundToInt(Mouse.Y)})";
		S += f"\ndrag mod found {FIS_bDragMod}, auto sort {bAuto} (blocked {FIS_AutoBlocked})";
		S += f"\ninventory: {FIS_InvInfo}";
		S += f"\nsorts {FIS_Sorts}, last without category {FIS_LastUnmatched}: {FIS_UnmatchedNames}";
		S += f"\nhotbar items: {FIS_LastHotbar}";
		S += f"\nscroll bar: {FIS_BarInfo}, dragging {FIS_bBarDragging}";
		S += f"\nactive: {FIS_ActiveInfo}";
		S += f"\nanimating: {FIS_AnimInfo}";
		S += f"\nfound by name+value {FIS_LastFullMatches}, names shared by different items {FIS_SharedNames}";
		S += f"\nlast: {FIS_LastAction}";
		FIS_DebugText.SetText(FText::FromString(S));
	}
}


// -------------------------------------------------------------------------------------
//  Helpers
// -------------------------------------------------------------------------------------

/** The biggest canvas ABOVE the inventory (the screens that contain it). */
UPanelWidget FIS_FindCanvasAbove(UUserWidget Base)
{
	FVector2D BaseSz = Base.GetCachedGeometry().GetAbsoluteSize();
	float64 BestArea = BaseSz.X * BaseSz.Y * 0.9;
	UPanelWidget Best = nullptr;

	UWidget Cur = Base;
	for (int Guard = 0; Guard < 60 && IsValid(Cur); Guard++)
	{
		UPanelWidget ParentPanel = Cur.GetParent();
		if (IsValid(ParentPanel))
		{
			if (IsValid(Cast<UCanvasPanel>(ParentPanel)))
			{
				FVector2D Sz = ParentPanel.GetCachedGeometry().GetAbsoluteSize();
				if (Sz.X * Sz.Y >= BestArea)
				{
					Best = ParentPanel;
					BestArea = Sz.X * Sz.Y;
				}
			}
			Cur = ParentPanel;
			continue;
		}
		UObject TreeObj = Cur.GetOuter();
		if (!IsValid(TreeObj))
			break;
		UUserWidget OwnerWidget = Cast<UUserWidget>(TreeObj.GetOuter());
		if (!IsValid(OwnerWidget) || OwnerWidget == Cur)
			break;
		Cur = OwnerWidget;
	}
	return Best;
}

/** The biggest canvas (not overlay) inside the inventory screen. */
UPanelWidget FIS_FindCanvasInside(UUserWidget Base)
{
	TArray<UWidget> All;
	Base.GetAllWidgets(All);
	All.Add(Base.GetRootWidget());
	UPanelWidget Best = nullptr;
	float64 BestArea = -1.0;
	for (int i = 0; i < All.Num(); i++)
	{
		UCanvasPanel C = Cast<UCanvasPanel>(All[i]);
		if (!IsValid(C))
			continue;
		FString CName = C.GetName().ToString();
		if (CName.StartsWith("FIS_") || CName.StartsWith("FIID_"))
			continue;
		FVector2D Sz = C.GetCachedGeometry().GetAbsoluteSize();
		if (Sz.X * Sz.Y > BestArea)
		{
			Best = C;
			BestArea = Sz.X * Sz.Y;
		}
	}
	return Best;
}

/** The biggest canvas or overlay inside the inventory screen. */
UPanelWidget FIS_FindPanelInside(UUserWidget Base)
{
	TArray<UWidget> All;
	Base.GetAllWidgets(All);
	All.Add(Base.GetRootWidget());

	UPanelWidget Best = nullptr;
	float64 BestArea = -1.0;
	for (int i = 0; i < All.Num(); i++)
	{
		UWidget W = All[i];
		if (!IsValid(W))
			continue;
		if (!IsValid(Cast<UCanvasPanel>(W)) && !IsValid(Cast<UOverlay>(W)))
			continue;
		FString WName = W.GetName().ToString();
		if (WName.StartsWith("FIS_") || WName.StartsWith("FIID_"))
			continue;
		FVector2D Sz = W.GetCachedGeometry().GetAbsoluteSize();
		float64 Area = Sz.X * Sz.Y;
		if (Area > BestArea)
		{
			Best = Cast<UPanelWidget>(W);
			BestArea = Area;
		}
	}
	return Best;
}

/** Adds Child so that it covers the whole host panel. */
void FIS_AddFullSize(UPanelWidget Host, UWidget Child, int ZOrder)
{
	UCanvasPanel Canvas = Cast<UCanvasPanel>(Host);
	if (IsValid(Canvas))
	{
		UCanvasPanelSlot CanvasSlot = Canvas.AddChildToCanvas(Child);
		if (IsValid(CanvasSlot))
		{
			FAnchors Stretch;
			Stretch.Minimum = FVector2D(0.0, 0.0);
			Stretch.Maximum = FVector2D(1.0, 1.0);
			CanvasSlot.SetAnchors(Stretch);
			CanvasSlot.SetPosition(FVector2D(0.0, 0.0));
			CanvasSlot.SetSize(FVector2D(0.0, 0.0));
			CanvasSlot.SetZOrder(ZOrder);
		}
		return;
	}

	UOverlaySlot OverlaySlot = Cast<UOverlaySlot>(Host.AddChild(Child));
	if (IsValid(OverlaySlot))
	{
		OverlaySlot.SetHorizontalAlignment(EHorizontalAlignment::HAlign_Fill);
		OverlaySlot.SetVerticalAlignment(EVerticalAlignment::VAlign_Fill);
	}
}

/** Adds a small widget at the canvas' top-left corner (it is moved with its render transform). */
void FIS_AddSmall(UCanvasPanel Canvas, UWidget Child, int ZOrder)
{
	UCanvasPanelSlot ChildSlot = Canvas.AddChildToCanvas(Child);
	if (IsValid(ChildSlot))
	{
		ChildSlot.SetAutoSize(false);
		ChildSlot.SetAlignment(FVector2D(0.0, 0.0));
		ChildSlot.SetPosition(FVector2D(0.0, 0.0));
		ChildSlot.SetSize(FVector2D(32.0, 32.0));
		ChildSlot.SetZOrder(ZOrder);
	}
}

/** Walks the widget tree ourselves, including the inside of nested user widgets. */
void FIS_Collect(UWidget W, TArray<UWidget>& Out, int Depth)
{
	if (!IsValid(W) || Depth > 30)
		return;
	if (Out.Contains(W))
		return;
	Out.Add(W);

	UUserWidget AsUserWidget = Cast<UUserWidget>(W);
	if (IsValid(AsUserWidget))
		FIS_Collect(AsUserWidget.GetRootWidget(), Out, Depth + 1);

	UPanelWidget AsPanel = Cast<UPanelWidget>(W);
	if (IsValid(AsPanel))
	{
		for (int i = 0; i < AsPanel.GetChildrenCount(); i++)
			FIS_Collect(AsPanel.GetChildAt(i), Out, Depth + 1);
	}
}
