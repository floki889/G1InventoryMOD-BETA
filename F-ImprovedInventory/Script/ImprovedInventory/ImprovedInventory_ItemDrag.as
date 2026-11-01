// =====================================================================================
//  Improved Inventory - part 2: drag items to swap places (order kept per save game)
//  (mod F-ImprovedInventory 1.3.6; part 1, Sort button + scroll bar, is ImprovedInventory_Sorting.as)
//  - The Sort button's order (part 1) is taken over.
//  - The order is kept PER SAVE GAME: it is stored in the game's save when you save,
//    and comes back when you load that save. Other saves and new games are not touched.
//  - Identical items (same name + value, e.g. several crossbows or arrow stacks) each get
//    their own place: "name|value#0", "#1" ... so dragging one moves only that one.
//  Drag an item in the inventory grid onto another item and the two swap places
//  (like the inventories of The Witcher 3 or World of Warcraft).
//  Drag an item out of the inventory window (to the right) and let go: it is dropped on the
//  floor, exactly like the game's "[Hold] Drop" (stacks ask how many).
//
//  How it works
//   - A widget extension is attached to the inventory screen (W_Inventory_Main, a UInventoryMain).
//   - An invisible "catcher" is put on top of every item tile of the grid. A quick left click is
//     handed back to the game as a normal click; right click, double click and the mouse wheel
//     go straight through to the game. Only a left press that MOVES starts a drag.
//   - Dropping on another tile swaps the two items in the mod's own order list. The game fills
//     the grid in its own order every time it refreshes; the mod then puts the items back into
//     the saved order (UDiscreteItemViewWidget.SetListItemsBP). The order is saved in the
//     game's own save (UFIID_GameOrder), so every save game has its own order.
//   - Items are recognised by name + value. New items go to the end of the grid.
//
//  Facts this relies on (read from the game files):
//   - UInventoryMain.TileView_Items is the item grid (UDiscreteItemViewWidget). Its list items
//     are UInventorySlotData objects (m_Name, m_Value, m_IconPath, m_Pos ...).
//   - The grid reports the hovered item (m_OnItemIsHoveredChangedBP) and can click its current
//     item (SetCurrentIndex + ClickCurrentItem), which is how a normal click is passed on.
//   - The tiles are created by the grid's TileView_Grid (UTileView): GetDisplayedEntryWidgets().
// =====================================================================================


/** The saved order of the items (one key per item: "name|value"). */
class UFIID_OrderSave : USaveGame
{
	UPROPERTY()
	TArray<FString> Order;
}

const FString FIID_SaveSlot = "FlokiInventoryItemDrag_Order";

/**
 * The order of the current game. Lives as long as the loaded game; its SaveGame properties go into
 * the game's save file when you save, and come back when that save is loaded.
 */
class UFIID_GameOrder : UGothicModExt_WorldSubsystem
{
	UPROPERTY(SaveGame)
	TArray<FString> FIID_Order;

	UPROPERTY(SaveGame)
	int FIID_SavedTimes = 0;      // how often this order went into a save (proves the save works)

	int FIID_Changes = 0;         // bumped when a game is loaded / started: the layer re-reads the order
	int FIID_LoadedKeys = -1;     // keys found right after loading a save (-1 = no save loaded yet)
	FString FIID_Events = "";

	UFUNCTION(BlueprintOverride)
	void HandleSaveGameLoaded()
	{
		FIID_LoadedKeys = FIID_Order.Num();
		FIID_Changes++;
		FIID_Events = f"save loaded: {FIID_Order.Num()} keys, saved {FIID_SavedTimes}x before";
	}

	UFUNCTION(BlueprintOverride)
	void HandleNewGameStarted()
	{
		FIID_Order.Empty();
		FIID_SavedTimes = 0;
		FIID_Changes++;
		FIID_Events = "new game: empty order";
	}

	UFUNCTION(BlueprintOverride)
	void HandleBeforeGameSaved()
	{
		FIID_SavedTimes++;
		FIID_Events = f"game saved with {FIID_Order.Num()} keys";
	}
}

/** Hover-event index the Sort button (part 1) sends after sorting ("take the grid's order over"). */
const int FIID_SortSignalIndex = -4242;


// -------------------------------------------------------------------------------------
//  Attaches the drag layer to the inventory screen.
// -------------------------------------------------------------------------------------
class UFIID_InventoryExtension : UGothicModExt_WidgetExtension
{
	default AddToWidgetOfClass = n"/Game/UI/ManagementUI/Inventory/W_Inventory_Main.W_Inventory_Main_C";

	UFIID_DragLayer FIID_Layer;

	UFUNCTION(BlueprintOverride)
	void Initialize()
	{
		FIID_TryInstall();
		System::SetTimer(this, n"FIID_OnTimer", 0.5f, true);
	}

	UFUNCTION(BlueprintOverride)
	void Tick(FGeometry MyGeometry, float InDeltaTime)
	{
		FIID_TryInstall();
	}

	UFUNCTION()
	private void FIID_OnTimer()
	{
		FIID_TryInstall();
	}

	void FIID_TryInstall()
	{
		if (IsValid(FIID_Layer))
			return;

		UUserWidget Base = GetWidget();
		if (!IsValid(Base))
			return;

		// Wait until the screen has been drawn once, so the biggest panel can be found.
		FVector2D BaseSize = Base.GetCachedGeometry().GetAbsoluteSize();
		if (BaseSize.X < 10.0 || BaseSize.Y < 10.0)
			return;

		UPanelWidget Host = FIID_FindHostPanel(Base);
		if (!IsValid(Host))
			return;

		// Our own full-size canvas on top of the screen: the drag layer, the dragged copy and the
		// debug text live on it, whatever kind of panel the game uses.
		UCanvasPanel OwnCanvas = Cast<UCanvasPanel>(Base.ConstructWidget(UCanvasPanel, n"FIID_Canvas"));
		if (!IsValid(OwnCanvas))
			return;
		FIID_AddFullSize(Host, OwnCanvas, 1000);
		OwnCanvas.SetVisibility(ESlateVisibility::SelfHitTestInvisible);

		UFIID_DragLayer Layer = Cast<UFIID_DragLayer>(Base.ConstructWidget(UFIID_DragLayer, n"FIID_DragLayer"));
		if (!IsValid(Layer))
			return;

		FIID_AddFullSize(OwnCanvas, Layer, 0);
		FVector2D HostSize = Host.GetCachedGeometry().GetAbsoluteSize();
		Layer.FIID_HostInfo = f"{Host.GetName().ToString()} ({Host.GetClass().GetName().ToString()}), {HostSize.X} x {HostSize.Y} px";
		Layer.FIID_Setup(Base, OwnCanvas);
		FIID_Layer = Layer;
	}
}


// -------------------------------------------------------------------------------------
//  Invisible widget on top of one item tile. Catches the left press so a drag can start.
// -------------------------------------------------------------------------------------
class UFIID_Catcher : UUserWidget
{
	UFIID_DragLayer FIID_Layer;
	UUserWidget FIID_Entry;      // the tile this catcher sits on

	UFUNCTION(BlueprintOverride)
	FEventReply OnMouseButtonDown(FGeometry MyGeometry, FPointerEvent MouseEvent)
	{
		if (!IsValid(FIID_Layer))
			return Widget::Unhandled();

		if (MouseEvent.GetEffectingButton() == EKeys::LeftMouseButton)
		{
			if (FIID_Layer.FIID_Press(this, MouseEvent.GetScreenSpacePosition()))
				return Widget::Handled();
			return Widget::Unhandled();
		}

		// Right click while dragging = cancel; otherwise the game gets it.
		if (FIID_Layer.FIID_bDragging)
		{
			FIID_Layer.FIID_Cancel("cancelled with another mouse button");
			return Widget::Handled();
		}
		return Widget::Unhandled();
	}

	// Double clicks go to the game (if the game ignores it, Slate sends it as a normal press).
	UFUNCTION(BlueprintOverride)
	FEventReply OnMouseButtonDoubleClick(FGeometry InMyGeometry, FPointerEvent InMouseEvent)
	{
		return Widget::Unhandled();
	}

	UFUNCTION(BlueprintOverride)
	FEventReply OnMouseButtonUp(FGeometry MyGeometry, FPointerEvent MouseEvent)
	{
		if (!IsValid(FIID_Layer) || !FIID_Layer.FIID_bPressing)
			return Widget::Unhandled();
		if (!(MouseEvent.GetEffectingButton() == EKeys::LeftMouseButton))
			return Widget::Handled();

		FIID_Layer.FIID_Release(true);
		return Widget::Handled();
	}
}


// -------------------------------------------------------------------------------------
//  Full-size layer on the inventory screen: keeps the order, shows the dragged icon, and
//  catches the release when the mouse is let go outside the tiles.
// -------------------------------------------------------------------------------------
class UFIID_DragLayer : UUserWidget
{
	// ============================ settings ============================

	// Debug readout in the top-left corner of the inventory. Set to false once everything works.
	bool FIID_Debug = false;

	// Small 2-line readout (bottom-right) about the per-save order. For testing; set to false later.
	bool FIID_SaveDebug = false;
	// Small readout (bottom-right) about the last drop by dragging. For testing; set to false later.
	bool FIID_DropDebug = false;

	// How far (in screen pixels) the mouse must move with the button held before a drag starts.
	float64 FIID_DragThreshold = 4.0;

	// Opacity of the tile you are dragging from (the item stays visible there, like in Witcher 3).
	float64 FIID_SourceOpacity = 0.5;

	// The picked-up copy of the item under the cursor.
	float64 FIID_GhostOpacity = 1.0;
	float64 FIID_GhostLift = 1.12;        // how much bigger it gets when picked up
	float64 FIID_GhostLiftTime = 0.10;    // seconds for the "pick up" grow animation
	float64 FIID_ShadowOffset = 7.0;      // shadow under the copy, in screen pixels
	float64 FIID_ShadowOpacity = 0.55;

	// true: the whole tile is picked up (white hover highlight, frame and item move together).
	// false: only the item picture moves (v0.2.4 behaviour).
	bool FIID_GhostWithTile = true;

	// Make the game's dark see-through background behind the item grid fully transparent.
	bool FIID_HideGridBackground = true;

	// Drop by dragging: let an item go to the right of the inventory window and it is dropped on
	// the floor (the game's own "[Hold] Drop", so stacks ask how many as usual).
	bool FIID_DropOutside = true;
	float64 FIID_DropZoneTiles = 1.0;       // drop zone starts this many tile widths right of the grid
	float64 FIID_DropZoneOpacity = 0.55;    // the dragged copy fades to this over the drop zone

	// ============================ state ============================

	UUserWidget FIID_Base;
	UPanelWidget FIID_Host;
	FString FIID_HostInfo = "-";
	bool FIID_bBackdropDone = false;
	FString FIID_BackdropInfo = "-";
	UTextBlock FIID_DebugText;
	UImage FIID_Ghost;
	UImage FIID_Shadow;
	UImage FIID_SrcIcon;            // the item picture inside the tile being dragged
	FVector2D FIID_GrabOffset;      // icon centre minus cursor, at the moment of the press
	FVector2D FIID_GhostAbsSize;
	float64 FIID_LiftAlpha = 0.0;
	int64 FIID_LastTicks = 0;
	int64 FIID_LastLayerTicks = 0;
	FString FIID_GhostInfo = "-";
	FString FIID_TileImages = "-";  // images found in the last dragged tile (debug)

	// Copies of all pictures of the dragged tile (highlight, frame, item ...), in drawing order.
	TArray<UImage> FIID_Parts;
	TArray<FVector2D> FIID_PartOffsets;   // part centre minus cursor at the press (screen px)
	TArray<FVector2D> FIID_PartSizes;     // part size (screen px)
	int FIID_PartCount = 0;
	int FIID_ShadowPart = -1;             // the biggest part: its outline is used for the shadow

	UInventoryMain FIID_Inv;
	UDiscreteItemViewWidget FIID_Grid;
	bool FIID_bHoverBound = false;
	bool FIID_bEntriesBound = false;
	TMap<UUserWidget, UObject> FIID_EntryItem;   // which item each tile shows (tile view event)
	FString FIID_DropInfo = "drop: -";
	// A drop waiting for the grid to show the game's own order (see FIID_DropItem).
	int FIID_PendPos = -1;
	FString FIID_PendKey = "";
	int64 FIID_PendUntil = 0;
	int FIID_PendScroll = 0;
	TArray<UObject> FIID_PendBefore;

	TArray<UUserWidget> FIID_Entries;
	TArray<UFIID_Catcher> FIID_Catchers;
	TArray<FString> FIID_EntryRootClasses;
	int FIID_InjectFailures = 0;

	UObject FIID_HoverItem;
	int FIID_HoverIndex = -1;

	bool FIID_bPressing = false;
	bool FIID_bDragging = false;
	FVector2D FIID_PressPos;
	UObject FIID_SrcItem;
	UFIID_Catcher FIID_SrcCatcher;
	UUserWidget FIID_DimmedEntry;

	UFIID_OrderSave FIID_Save;         // working copy of the order (kept in UFIID_GameOrder)
	UFIID_GameOrder FIID_GameState;
	int FIID_GameStateChanges = -1;
	UTextBlock FIID_SaveText;
	TArray<UObject> FIID_LastApplied;
	int FIID_Reorders = 0;
	int FIID_KeepScrollOffset = 0;
	int FIID_KeepScrollFrames = 0;
	int FIID_Swaps = 0;
	int FIID_Drops = 0;
	int FIID_Adopted = 0;
	FString FIID_LastAction = "-";

	// ------------------------------------------------------------------
	//  Setup
	// ------------------------------------------------------------------

	void FIID_Setup(UUserWidget Base, UPanelWidget Host)
	{
		FIID_Base = Base;
		FIID_Host = Host;
		SetVisibility(ESlateVisibility::HitTestInvisible);
		FIID_SyncWithGame();
		if (!IsValid(FIID_Save))
			FIID_LoadOrder();

		UCanvasPanel Canvas = Cast<UCanvasPanel>(Host);
		if (IsValid(Canvas))
		{
			// The picked-up copy of the item that follows the cursor, and its shadow.
			FIID_Shadow = FIID_MakeFloatingImage(Base, Canvas, n"FIID_Shadow", 1001);
			FIID_Ghost = FIID_MakeFloatingImage(Base, Canvas, n"FIID_Ghost", 1002);

			if (FIID_SaveDebug || FIID_DropDebug)
			{
				FIID_SaveText = Cast<UTextBlock>(Base.ConstructWidget(UTextBlock, n"FIID_SaveText"));
				if (IsValid(FIID_SaveText))
				{
					UCanvasPanelSlot SaveSlot = Canvas.AddChildToCanvas(FIID_SaveText);
					if (IsValid(SaveSlot))
					{
						FAnchors BottomRight;
						BottomRight.Minimum = FVector2D(1.0, 1.0);
						BottomRight.Maximum = FVector2D(1.0, 1.0);
						SaveSlot.SetAnchors(BottomRight);
						SaveSlot.SetAlignment(FVector2D(1.0, 1.0));
						SaveSlot.SetAutoSize(false);
						SaveSlot.SetSize(FVector2D(1400.0, 120.0));
						SaveSlot.SetPosition(FVector2D(-30.0, -140.0));
						SaveSlot.SetZOrder(1003);
					}
					FIID_SaveText.SetVisibility(ESlateVisibility::HitTestInvisible);
					FIID_SaveText.SetRenderTransformPivot(FVector2D(1.0, 1.0));
					FIID_SaveText.SetRenderScale(FVector2D(0.55, 0.55));
				}
			}

			if (FIID_Debug)
			{
				FIID_DebugText = Cast<UTextBlock>(Base.ConstructWidget(UTextBlock, n"FIID_DebugText"));
				if (IsValid(FIID_DebugText))
				{
					// Top-right corner of the screen, fixed size (so it never changes the layout).
					UCanvasPanelSlot TextSlot = Canvas.AddChildToCanvas(FIID_DebugText);
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
						TextSlot.SetZOrder(1003);
					}
					FIID_DebugText.SetVisibility(ESlateVisibility::HitTestInvisible);
					FIID_DebugText.SetRenderTransformPivot(FVector2D(1.0, 0.0));
					FIID_DebugText.SetRenderScale(FVector2D(0.55, 0.55));
				}
			}
		}

		FIID_LastAction = f"installed on {Base.GetClass().GetName().ToString()}, host {Host.GetName().ToString()} ({Host.GetClass().GetName().ToString()})";
	}

	// ------------------------------------------------------------------
	//  Every frame while the inventory is shown
	// ------------------------------------------------------------------

	UFUNCTION(BlueprintOverride)
	void Tick(FGeometry MyGeometry, float InDeltaTime)
	{
		// The screen is not drawn (no ticks) while closed: a gap means it was closed and reopened,
		// so a drag that was going on is dropped.
		int64 NowTicks = FDateTime::Now().GetTicks();
		if (FIID_LastLayerTicks > 0 && NowTicks - FIID_LastLayerTicks > 3000000 && FIID_bPressing)
			FIID_Cancel("inventory was closed during a drag");
		FIID_LastLayerTicks = NowTicks;

		FIID_SyncWithGame();
		FIID_FindGrid();

		if (IsValid(FIID_Grid))
		{
			FIID_InjectCatchers();
			if (FIID_HideGridBackground && !FIID_bBackdropDone)
				FIID_HideGridBackdrop();
			if (FIID_PendPos >= 0)
				FIID_TryPendingDrop();
			else if (!FIID_bDragging)
				FIID_ApplyOrder();

			// For a few frames after re-sorting, hold the grid at the scroll position it had.
			if (FIID_KeepScrollFrames > 0)
			{
				FIID_KeepScrollFrames--;
				if (FIID_Grid.GetCurrentScrollOffset() != FIID_KeepScrollOffset)
					FIID_Grid.SetScrollOffset(FIID_KeepScrollOffset);
			}
		}

		FVector2D Mouse = WidgetLayout::GetMousePositionOnPlatform();

		// A press turns into a drag once the mouse has moved far enough.
		if (FIID_bPressing && !FIID_bDragging && FIID_Dist(Mouse, FIID_PressPos) > FIID_DragThreshold)
			FIID_StartDrag();

		if (FIID_bDragging)
			FIID_UpdateGhost(Mouse);

		// While dragging, this layer catches the release everywhere except on the tiles
		// (there the tile's catcher gets it and the game keeps showing which tile is hovered).
		bool bCatch = FIID_bDragging && !FIID_IsOverCatcher(Mouse);
		ESlateVisibility Wanted = bCatch ? ESlateVisibility::Visible : ESlateVisibility::HitTestInvisible;
		if (GetVisibility() != Wanted)
			SetVisibility(Wanted);

		if (FIID_Debug)
			FIID_UpdateDebugText(Mouse);
		if (IsValid(FIID_SaveText))
			FIID_UpdateSaveText();
	}

	/** Takes the order of the currently loaded game (again) when a game was loaded or started. */
	void FIID_SyncWithGame()
	{
		UFIID_GameOrder State = UFIID_GameOrder::Get();
		if (!IsValid(State))
			return;
		if (State == FIID_GameState && State.FIID_Changes == FIID_GameStateChanges)
			return;
		FIID_GameState = State;
		FIID_GameStateChanges = State.FIID_Changes;
		FIID_LoadOrder();
		FIID_LastApplied.Empty();   // put the grid into this game's order
		FIID_LastAction = f"order of this game taken: {FIID_Save.Order.Num()} keys";
	}

	void FIID_UpdateSaveText()
	{
		if (!FIID_SaveDebug)
		{
			FIID_SaveText.SetText(FText::FromString(FIID_DropInfo));
			return;
		}
		FString S = "InventoryItemDrag - order per save";
		if (IsValid(FIID_GameState))
			S += f"\nthis game: {FIID_GameState.FIID_Order.Num()} keys, in saves {FIID_GameState.FIID_SavedTimes}x, after load {FIID_GameState.FIID_LoadedKeys} | {FIID_GameState.FIID_Events}";
		else
			S += "\ngame state NOT found (order is not kept)";
		FIID_SaveText.SetText(FText::FromString(S));
	}

	void FIID_FindGrid()
	{
		if (IsValid(FIID_Grid))
			return;
		FIID_Inv = Cast<UInventoryMain>(FIID_Base);
		if (!IsValid(FIID_Inv))
		{
			FIID_LastAction = "the screen is not a UInventoryMain";
			return;
		}
		FIID_Grid = FIID_Inv.TileView_Items;
		if (!IsValid(FIID_Grid))
		{
			FIID_LastAction = "item grid (TileView_Items) not found yet";
			return;
		}
		if (!FIID_bHoverBound)
		{
			FIID_Grid.m_OnItemIsHoveredChangedBP.AddUFunction(this, n"FIID_OnHoverChanged");
			FIID_bHoverBound = true;
		}
		if (!FIID_bEntriesBound && IsValid(FIID_Grid.TileView_Grid))
		{
			FIID_Grid.TileView_Grid.BP_OnEntryInitialized.AddUFunction(this, n"FIID_OnEntryInitialized");
			FIID_bEntriesBound = true;
			FIID_Grid.TileView_Grid.RegenerateAllEntries();   // tiles already shown report too
		}
		FIID_LastApplied.Empty();
		FIID_LastAction = "item grid found";
	}

	UFUNCTION()
	private void FIID_OnEntryInitialized(UObject Item, UUserWidget Widget)
	{
		if (IsValid(Widget))
			FIID_EntryItem.Add(Widget, Item);
	}

	/** The item shown on a tile (nullptr if unknown or no longer in the grid). */
	UObject FIID_ItemOfEntry(UUserWidget Entry)
	{
		UObject Item = nullptr;
		if (!IsValid(Entry) || !FIID_EntryItem.Find(Entry, Item) || !IsValid(Item))
			return nullptr;
		if (FIID_Grid.GetIndexForItem(Item) < 0)
			return nullptr;
		return Item;
	}

	UFUNCTION()
	private void FIID_OnHoverChanged(int _Index, UObject _Item, bool _IsHovered)
	{
		// Message from part 1 (Sort button): it has just sorted the grid -> take that order over.
		if (_Index == FIID_SortSignalIndex)
		{
			if (IsValid(_Item) && _Item.GetName().ToString().StartsWith("FIS_"))
				FIID_AdoptGridOrder();
			return;
		}

		if (_IsHovered)
		{
			FIID_HoverItem = _Item;
			FIID_HoverIndex = _Index;
		}
		else if (FIID_HoverItem == _Item)
		{
			FIID_HoverItem = nullptr;
			FIID_HoverIndex = -1;
		}
	}

	// ------------------------------------------------------------------
	//  Catchers on the tiles
	// ------------------------------------------------------------------

	void FIID_InjectCatchers()
	{
		UTileView Tiles = FIID_Grid.TileView_Grid;
		if (!IsValid(Tiles))
			return;

		TArray<UUserWidget> Shown = Tiles.GetDisplayedEntryWidgets();
		for (int i = 0; i < Shown.Num(); i++)
		{
			UUserWidget Entry = Shown[i];
			if (!IsValid(Entry))
				continue;

			int Known = FIID_Entries.FindIndex(Entry);
			if (Known >= 0)
			{
				UFIID_Catcher Existing = FIID_Catchers[Known];
				if (IsValid(Existing) && IsValid(Existing.GetParent()))
					continue;
				FIID_Entries.RemoveAt(Known);
				FIID_Catchers.RemoveAt(Known);
			}

			UPanelWidget Panel = FIID_FindTilePanel(Entry);
			if (!IsValid(Panel))
			{
				FIID_InjectFailures++;
				FIID_NoteRootClass(Entry, "no panel");
				continue;
			}

			UFIID_Catcher NewCatcher = Cast<UFIID_Catcher>(Entry.ConstructWidget(UFIID_Catcher, n"FIID_Catcher"));
			if (!IsValid(NewCatcher))
			{
				FIID_InjectFailures++;
				continue;
			}
			NewCatcher.FIID_Layer = this;
			NewCatcher.FIID_Entry = Entry;
			FIID_AddFullSize(Panel, NewCatcher, 1000);
			NewCatcher.SetVisibility(ESlateVisibility::Visible);

			FIID_Entries.Add(Entry);
			FIID_Catchers.Add(NewCatcher);
			FIID_NoteRootClass(Entry, Panel.GetClass().GetName().ToString());
		}
	}

	/** The outermost canvas or overlay inside a tile (a catcher can be stretched over it). */
	UPanelWidget FIID_FindTilePanel(UUserWidget Entry)
	{
		TArray<UWidget> Level;
		Level.Add(Entry.GetRootWidget());
		for (int Depth = 0; Depth < 8 && Level.Num() > 0; Depth++)
		{
			TArray<UWidget> NextLevel;
			for (int i = 0; i < Level.Num(); i++)
			{
				UWidget W = Level[i];
				if (!IsValid(W))
					continue;
				if (IsValid(Cast<UCanvasPanel>(W)) || IsValid(Cast<UOverlay>(W)))
					return Cast<UPanelWidget>(W);
				UPanelWidget AsPanel = Cast<UPanelWidget>(W);
				if (IsValid(AsPanel))
				{
					for (int c = 0; c < AsPanel.GetChildrenCount(); c++)
						NextLevel.Add(AsPanel.GetChildAt(c));
				}
			}
			Level = NextLevel;
		}
		return nullptr;
	}

	void FIID_NoteRootClass(UUserWidget Entry, FString PanelInfo)
	{
		UWidget Root = Entry.GetRootWidget();
		FString RootName = IsValid(Root) ? Root.GetClass().GetName().ToString() : "none";
		FString Info = f"{Entry.GetClass().GetName().ToString()} root {RootName} -> {PanelInfo}";
		if (!FIID_EntryRootClasses.Contains(Info))
			FIID_EntryRootClasses.Add(Info);
	}

	bool FIID_IsOverCatcher(FVector2D P)
	{
		for (int i = 0; i < FIID_Catchers.Num(); i++)
		{
			UFIID_Catcher C = FIID_Catchers[i];
			if (!IsValid(C) || !C.IsVisible())
				continue;
			if (FIID_Contains(C, P))
				return true;
		}
		return false;
	}

	// ------------------------------------------------------------------
	//  Press / drag / release
	// ------------------------------------------------------------------

	/** Left press on a tile. Returns true if the mod takes the press. */
	bool FIID_Press(UFIID_Catcher Catcher, FVector2D P)
	{
		if (FIID_bDragging)
			FIID_Cancel("new press while dragging");

		if (!IsValid(FIID_Grid))
			return false;

		// The item on the pressed tile itself; the game's hover info only as a fallback.
		UObject Item = IsValid(Catcher) ? FIID_ItemOfEntry(Catcher.FIID_Entry) : nullptr;
		if (!IsValid(Item))
			Item = FIID_HoverItem;
		if (!IsValid(Item))
			Item = FIID_Grid.GetHoveredOrSelectedItem();
		if (!IsValid(Item) || FIID_KeyOf(Item) == "")
		{
			FIID_LastAction = "press on a tile without a known item: passed to the game";
			return false;
		}

		FIID_bPressing = true;
		FIID_PressPos = P;
		FIID_SrcItem = Item;
		FIID_SrcCatcher = Catcher;
		FIID_LastAction = f"press on {FIID_KeyOf(Item)}";
		return true;
	}

	void FIID_StartDrag()
	{
		FIID_bDragging = true;
		FIID_LiftAlpha = 0.0;
		FIID_LastTicks = 0;

		UUserWidget SrcEntry = IsValid(FIID_SrcCatcher) ? FIID_SrcCatcher.FIID_Entry : nullptr;

		// The copy: the exact picture of the item, taken from the tile itself.
		FIID_SrcIcon = FIID_FindIconImage(SrcEntry);
		bool bHavePicture = false;
		if (IsValid(FIID_Ghost) && IsValid(FIID_SrcIcon))
		{
			FIID_Ghost.SetBrush(FIID_SrcIcon.Brush);
			if (IsValid(FIID_Shadow))
				FIID_Shadow.SetBrush(FIID_SrcIcon.Brush);
			bHavePicture = true;
			FIID_GhostInfo = f"picture from tile image '{FIID_SrcIcon.GetName().ToString()}'";
		}
		else
		{
			// Fallback: the item's icon texture.
			UInventorySlotData Data = Cast<UInventorySlotData>(FIID_SrcItem);
			UTexture2D Tex = IsValid(Data) ? Data.m_IconPath.Get() : nullptr;
			if (IsValid(FIID_Ghost) && IsValid(Tex))
			{
				FIID_Ghost.SetBrushFromTexture(Tex, false);
				if (IsValid(FIID_Shadow))
					FIID_Shadow.SetBrushFromTexture(Tex, false);
				bHavePicture = true;
				FIID_GhostInfo = "picture from the item's icon texture";
			}
			else
			{
				FIID_GhostInfo = "no picture found (no icon image in the tile, icon texture not loaded)";
			}
		}

		// Size of the copy = size of the picture in the tile; the grab point stays under the cursor.
		FVector2D IconCenter = FIID_PressPos;
		FIID_GhostAbsSize = FVector2D(80.0, 80.0);
		UWidget SizeRef = IsValid(FIID_SrcIcon) ? Cast<UWidget>(FIID_SrcIcon) : Cast<UWidget>(FIID_SrcCatcher);
		if (IsValid(SizeRef))
		{
			FGeometry G = SizeRef.GetCachedGeometry();
			FVector2D Sz = G.GetLocalSize();
			if (Sz.X > 1.0 && Sz.Y > 1.0)
			{
				IconCenter = G.LocalToAbsolute(Sz * 0.5);
				FIID_GhostAbsSize = G.GetAbsoluteSize();
			}
		}
		FIID_GrabOffset = IconCenter - FIID_PressPos;

		if (bHavePicture)
		{
			FIID_Ghost.SetColorAndOpacity(FLinearColor(1.0, 1.0, 1.0, 1.0));
			FIID_Ghost.SetRenderOpacity(FIID_GhostOpacity);
			FIID_Ghost.SetVisibility(ESlateVisibility::HitTestInvisible);
			if (IsValid(FIID_Shadow))
			{
				FIID_Shadow.SetColorAndOpacity(FLinearColor(0.0, 0.0, 0.0, 1.0));
				FIID_Shadow.SetRenderOpacity(FIID_ShadowOpacity);
				FIID_Shadow.SetVisibility(ESlateVisibility::HitTestInvisible);
			}
		}

		// Pick up the whole tile (hover highlight + frame + item) instead of just the picture.
		FIID_PartCount = 0;
		FIID_ShadowPart = -1;
		if (FIID_GhostWithTile && IsValid(SrcEntry))
			FIID_CopyTileParts(SrcEntry);
		if (FIID_PartCount > 0)
		{
			FIID_Ghost.SetVisibility(ESlateVisibility::Collapsed);
			if (IsValid(FIID_Shadow))
			{
				if (FIID_ShadowPart >= 0)
				{
					FIID_Shadow.SetBrush(FIID_Parts[FIID_ShadowPart].Brush);
					FIID_Shadow.SetColorAndOpacity(FLinearColor(0.0, 0.0, 0.0, 1.0));
					FIID_Shadow.SetRenderOpacity(FIID_ShadowOpacity);
					FIID_Shadow.SetVisibility(ESlateVisibility::HitTestInvisible);
				}
				else
				{
					FIID_Shadow.SetVisibility(ESlateVisibility::Collapsed);
				}
			}
			FIID_GhostInfo = f"whole tile picked up ({FIID_PartCount} pictures)";
		}

		// The item stays in its slot, just dimmed (like in Witcher 3).
		if (IsValid(SrcEntry))
		{
			FIID_DimmedEntry = SrcEntry;
			FIID_DimmedEntry.SetRenderOpacity(FIID_SourceOpacity);
		}

		FIID_UpdateGhost(WidgetLayout::GetMousePositionOnPlatform());
		FIID_LastAction = f"dragging {FIID_KeyOf(FIID_SrcItem)}";
	}

	/**
	 * Copies every picture the tile shows right now (the cursor is on it, so the white hover
	 * highlight is showing too) onto floating images, keeping their positions relative to the
	 * cursor. Small markers (hotbar number box, "new" marks, amounts) are left out.
	 */
	void FIID_CopyTileParts(UUserWidget Entry)
	{
		UCanvasPanel Canvas = Cast<UCanvasPanel>(FIID_Host);
		if (!IsValid(Canvas))
			return;

		TArray<UWidget> All;
		FIID_Collect(Entry.GetRootWidget(), All, 0);
		FVector2D TileSz = Entry.GetCachedGeometry().GetAbsoluteSize();
		// Small pictures (the amount box in the corner, markers) stay behind: only the big ones
		// (hover highlight, frame, item) are picked up.
		float64 MinArea = TileSz.X * TileSz.Y * 0.15;

		FIID_PartOffsets.Empty();
		FIID_PartSizes.Empty();
		float64 BiggestArea = -1.0;
		for (int i = 0; i < All.Num(); i++)
		{
			UImage Img = Cast<UImage>(All[i]);
			if (!IsValid(Img) || !Img.IsVisible() || Img.GetRenderOpacity() <= 0.01)
				continue;
			FString ImgName = Img.GetName().ToString();
			if (ImgName.Contains("Hotkey") || ImgName.Contains("Amount") || ImgName.Contains("Count")
				|| ImgName.Contains("Number") || ImgName.Contains("Unseen") || ImgName.Contains("Notification"))
				continue;

			FGeometry G = Img.GetCachedGeometry();
			FVector2D LocalSz = G.GetLocalSize();
			FVector2D AbsSz = G.GetAbsoluteSize();
			if (LocalSz.X <= 0.0 || LocalSz.Y <= 0.0 || AbsSz.X * AbsSz.Y < MinArea)
				continue;

			// Floating image for this part (created once, reused).
			if (FIID_PartCount >= FIID_Parts.Num())
			{
				FName PartName = FName(f"FIID_Part{FIID_PartCount}");
				UImage NewPart = FIID_MakeFloatingImage(FIID_Base, Canvas, PartName, 1002 + FIID_PartCount);
				if (!IsValid(NewPart))
					break;
				FIID_Parts.Add(NewPart);
			}
			UImage Part = FIID_Parts[FIID_PartCount];
			Part.SetBrush(Img.Brush);
			Part.SetColorAndOpacity(Img.ColorAndOpacity);
			Part.SetRenderOpacity(Img.GetRenderOpacity() * FIID_GhostOpacity);
			Part.SetVisibility(ESlateVisibility::HitTestInvisible);

			FVector2D PartCenter = G.LocalToAbsolute(LocalSz * 0.5);
			FIID_PartOffsets.Add(PartCenter - FIID_PressPos);
			FIID_PartSizes.Add(AbsSz);
			if (AbsSz.X * AbsSz.Y > BiggestArea)
			{
				BiggestArea = AbsSz.X * AbsSz.Y;
				FIID_ShadowPart = FIID_PartCount;
			}
			FIID_PartCount++;
		}
	}

	/**
	 * The item picture inside a tile. Skips the hotbar number box, frames, highlights and other
	 * small markers; prefers an image named like "Item"/"Icon" that is at least a third of the
	 * tile's size, else the biggest such image.
	 */
	UImage FIID_FindIconImage(UUserWidget Entry)
	{
		FIID_TileImages = "";
		if (!IsValid(Entry))
			return nullptr;
		TArray<UWidget> All;
		FIID_Collect(Entry.GetRootWidget(), All, 0);

		FVector2D TileSz = Entry.GetCachedGeometry().GetAbsoluteSize();
		float64 MinArea = TileSz.X * TileSz.Y * 0.11;   // ~1/3 of the tile's width and height

		UImage ByName = nullptr;
		float64 ByNameArea = -1.0;
		UImage Biggest = nullptr;
		float64 BiggestArea = -1.0;
		for (int i = 0; i < All.Num(); i++)
		{
			UImage Img = Cast<UImage>(All[i]);
			if (!IsValid(Img))
				continue;
			FString ImgName = Img.GetName().ToString();
			FVector2D Sz = Img.GetCachedGeometry().GetAbsoluteSize();
			float64 Area = Sz.X * Sz.Y;
			FString HiddenNote = Img.IsVisible() ? "" : " (hidden)";
			int ImgW = Math::RoundToInt(Sz.X);
			int ImgH = Math::RoundToInt(Sz.Y);
			FIID_TileImages += f"{ImgName} {ImgW}x{ImgH}{HiddenNote}, ";

			if (!Img.IsVisible() || Area < MinArea)
				continue;
			if (ImgName.Contains("Hotkey") || ImgName.Contains("Background") || ImgName.Contains("Frame")
				|| ImgName.Contains("Hover") || ImgName.Contains("Glow") || ImgName.Contains("Border")
				|| ImgName.Contains("Bg") || ImgName.Contains("Select") || ImgName.Contains("Highlight")
				|| ImgName.Contains("Unseen") || ImgName.Contains("Amount") || ImgName.Contains("Count")
				|| ImgName.Contains("Number") || ImgName.Contains("Notification") || ImgName.Contains("Slot"))
				continue;
			if ((ImgName.Contains("Item") || ImgName.Contains("Icon")) && Area > ByNameArea)
			{
				ByName = Img;
				ByNameArea = Area;
			}
			if (Area > BiggestArea)
			{
				Biggest = Img;
				BiggestArea = Area;
			}
		}
		if (IsValid(ByName))
			return ByName;
		return Biggest;
	}

	/** Left button let go. bOnTile = released over a tile's catcher. */
	void FIID_Release(bool bOnTile)
	{
		if (!FIID_bPressing)
			return;

		if (!FIID_bDragging)
		{
			// It was just a click: hand it to the game.
			FIID_EndDrag();
			FIID_PassClick(FIID_SrcItem);
			return;
		}

		UObject Target = bOnTile ? FIID_HoverItem : nullptr;
		UObject Src = FIID_SrcItem;
		bool bDrop = !bOnTile && FIID_IsInDropZone(WidgetLayout::GetMousePositionOnPlatform());
		FIID_EndDrag();

		if (bDrop)
		{
			FIID_DropItem(Src);
			return;
		}

		if (!IsValid(Target) || Target == Src)
		{
			FIID_LastAction = "dropped outside the other items: nothing changed";
			return;
		}
		FIID_Swap(Src, Target);
	}

	void FIID_Cancel(FString Why)
	{
		FIID_EndDrag();
		FIID_LastAction = Why;
	}

	void FIID_EndDrag()
	{
		FIID_bPressing = false;
		FIID_bDragging = false;
		if (IsValid(FIID_DimmedEntry))
			FIID_DimmedEntry.SetRenderOpacity(1.0);
		FIID_DimmedEntry = nullptr;
		if (IsValid(FIID_Ghost))
			FIID_Ghost.SetVisibility(ESlateVisibility::Collapsed);
		if (IsValid(FIID_Shadow))
			FIID_Shadow.SetVisibility(ESlateVisibility::Collapsed);
		for (int i = 0; i < FIID_Parts.Num(); i++)
		{
			if (IsValid(FIID_Parts[i]))
				FIID_Parts[i].SetVisibility(ESlateVisibility::Collapsed);
		}
		FIID_PartCount = 0;
		if (IsValid(FIID_Host))
			FIID_Host.SetRenderOpacity(1.0);
		SetVisibility(ESlateVisibility::HitTestInvisible);
	}

	// ------------------------------------------------------------------
	//  Drop by dragging out of the inventory window
	// ------------------------------------------------------------------

	/** Is this screen point right of the inventory window (where letting go drops the item)? */
	bool FIID_IsInDropZone(FVector2D P)
	{
		if (!FIID_DropOutside || !IsValid(FIID_Grid))
			return false;
		FGeometry G = FIID_Grid.GetCachedGeometry();
		FVector2D GridSize = G.GetLocalSize();
		if (GridSize.X <= 0.0)
			return false;
		float64 GridRight = G.LocalToAbsolute(GridSize).X;
		float64 TileW = 0.0;
		for (int i = 0; i < FIID_Entries.Num() && TileW <= 0.0; i++)
		{
			if (IsValid(FIID_Entries[i]))
				TileW = FIID_Entries[i].GetCachedGeometry().GetAbsoluteSize().X;
		}
		if (TileW <= 0.0)
			TileW = G.GetAbsoluteSize().X * 0.2;
		return P.X > GridRight + TileW * FIID_DropZoneTiles;
	}

	/**
	 * Drops the item on the floor the game's way: a "hold right mouse button" on it (its
	 * "[Hold] Drop"). For a stack the game asks how many, as usual.
	 *
	 * The game's drop takes the TILE NUMBER and looks it up in its own, unsorted list. Our grid
	 * is sorted / merged, so tile 13 on screen can be another item in the game's list. So: let
	 * the game refill the grid in its own order (merging and re-sorting paused), find the item's
	 * tile number there, drop that, then sort / merge again.
	 */
	void FIID_DropItem(UObject Item)
	{
		UInventorySlotData Data = Cast<UInventorySlotData>(Item);
		if (!IsValid(FIID_Grid) || !IsValid(FIID_Inv) || !IsValid(Data))
			return;
		FIID_PendPos = Data.m_Pos;
		FIID_PendKey = FIID_KeyOf(Item);
		FIID_PendUntil = FDateTime::Now().GetTicks() + 10000000;   // give up after 1 s
		FIID_PendScroll = FIID_Grid.GetCurrentScrollOffset();
		FIID_PendBefore = FIID_Grid.GetListItems();
		FIST_PauseMerging(true);
		FIID_Inv.RefreshInventory(true);
		FIID_TryPendingDrop();
	}

	/** Drops the waiting item as soon as the grid shows the game's own order. */
	void FIID_TryPendingDrop()
	{
		if (FIID_PendPos < 0 || !IsValid(FIID_Grid))
			return;
		TArray<UObject> Items = FIID_Grid.GetListItems();

		// The game's own order: the list was refilled (new list) or is in the game's order.
		bool bGameOrder = !FIID_SameList(Items, FIID_PendBefore);
		if (!bGameOrder)
		{
			bGameOrder = true;
			int LastPos = -1;
			for (int i = 0; i < Items.Num(); i++)
			{
				UInventorySlotData D = Cast<UInventorySlotData>(Items[i]);
				int P = IsValid(D) ? D.m_Pos : -1;
				if (P < LastPos)
				{
					bGameOrder = false;
					break;
				}
				LastPos = P;
			}
		}
		int Index = -1;
		if (bGameOrder)
		{
			for (int i = 0; i < Items.Num(); i++)
			{
				UInventorySlotData D = Cast<UInventorySlotData>(Items[i]);
				if (IsValid(D) && D.m_Pos == FIID_PendPos && FIID_KeyOf(D) == FIID_PendKey)
				{
					Index = i;
					break;
				}
			}
		}
		if (Index < 0)
		{
			if (FDateTime::Now().GetTicks() > FIID_PendUntil)
			{
				FIID_DropInfo = f"drop: {FIID_PendKey} pos {FIID_PendPos} | CANCELLED (game order {bGameOrder}, not found)";
				FIID_EndPendingDrop();
			}
			return;
		}

		UObject Target = Items[Index];
		FIID_Grid.ClearHoverItem();
		FIID_Grid.SetCurrentIndex(Index);
		FIID_Grid.m_OnItemIsHoveredChangedBP.Broadcast(Index, Target, true);
		UObject Pointed = FIID_Grid.GetHoveredOrSelectedItem();
		FIID_DropInfo = f"drop: {FIID_PendKey} pos {FIID_PendPos} -> game tile {Index} | points at {FIID_KeyOf(Pointed)} | {Items.Num()} tiles";
		if (Pointed != Target)
		{
			FIID_DropInfo += " | CANCELLED";
			FIID_EndPendingDrop();
			return;
		}
		bool bDone = FIID_Grid.LongClickCurrentItem(EAlkMouseButton::Right);
		FIID_Drops++;
		FIID_LastAction = f"dropped by dragging out: {FIID_PendKey} (game tile {Index}, handled {bDone})";
		FIID_EndPendingDrop();
	}

	/** Back to normal: sorting / merging go on, the grid returns to its row. */
	void FIID_EndPendingDrop()
	{
		FIID_PendPos = -1;
		FIID_PendBefore.Empty();
		FIST_PauseMerging(false);
		FIID_LastApplied.Empty();   // put the grid back into the saved order
		FIID_KeepScrollOffset = FIID_PendScroll;
		FIID_KeepScrollFrames = 12;
	}

	/** Does what a normal left click on that item would do. */
	void FIID_PassClick(UObject Item)
	{
		if (!IsValid(FIID_Grid) || !IsValid(Item))
			return;
		int Index = FIID_Grid.GetIndexForItem(Item);
		if (Index < 0)
			return;
		FIID_Grid.SetCurrentIndex(Index);
		bool bDone = FIID_Grid.ClickCurrentItem(EAlkMouseButton::Left);
		FIID_LastAction = f"click passed to the game: {FIID_KeyOf(Item)} (index {Index}, handled {bDone})";
	}

	/** Moves the picked-up copy (and its shadow) with the cursor, with a short "lift" animation. */
	void FIID_UpdateGhost(FVector2D Mouse)
	{
		if (!IsValid(FIID_Ghost) || !IsValid(FIID_Host))
			return;

		// Time since the last frame (for the lift animation).
		int64 NowTicks = FDateTime::Now().GetTicks();
		float64 Dt = 0.0;
		if (FIID_LastTicks > 0)
			Dt = float64(NowTicks - FIID_LastTicks) / 10000000.0;
		FIID_LastTicks = NowTicks;
		if (FIID_GhostLiftTime > 0.0)
			FIID_LiftAlpha += Dt / FIID_GhostLiftTime;
		else
			FIID_LiftAlpha = 1.0;
		if (FIID_LiftAlpha > 1.0)
			FIID_LiftAlpha = 1.0;
		float64 Ease = 1.0 - (1.0 - FIID_LiftAlpha) * (1.0 - FIID_LiftAlpha);
		float64 Scale = 1.0 + (FIID_GhostLift - 1.0) * Ease;

		// Over the drop zone the copy fades: letting go there drops the item.
		float64 Fade = FIID_IsInDropZone(Mouse) ? FIID_DropZoneOpacity : 1.0;
		if (FIID_Host.GetRenderOpacity() != Fade)
			FIID_Host.SetRenderOpacity(Fade);

		FGeometry HostGeo = FIID_Host.GetCachedGeometry();
		float64 AbsW = HostGeo.GetAbsoluteSize().X;
		float64 PxScale = AbsW > 0.0 ? HostGeo.GetLocalSize().X / AbsW : 1.0;
		float64 ShadowPx = FIID_ShadowOffset * Ease;

		// Whole tile: every part keeps its place relative to the cursor (the group grows around it).
		if (FIID_PartCount > 0)
		{
			for (int i = 0; i < FIID_PartCount && i < FIID_Parts.Num(); i++)
			{
				FVector2D PartCenter = Mouse + FIID_PartOffsets[i] * Scale;
				FIID_PlaceFloating(FIID_Parts[i], HostGeo.AbsoluteToLocal(PartCenter), FIID_PartSizes[i] * PxScale, Scale);
			}
			if (FIID_ShadowPart >= 0 && FIID_ShadowPart < FIID_PartCount)
			{
				FVector2D ShadowCenter = Mouse + FIID_PartOffsets[FIID_ShadowPart] * Scale + FVector2D(ShadowPx, ShadowPx);
				FIID_PlaceFloating(FIID_Shadow, HostGeo.AbsoluteToLocal(ShadowCenter), FIID_PartSizes[FIID_ShadowPart] * PxScale, Scale);
			}
			return;
		}

		FVector2D BaseSize = FIID_GhostAbsSize * PxScale;

		// Keep the spot you grabbed under the cursor (the copy grows around it).
		FVector2D Center = Mouse + FIID_GrabOffset * Scale;
		FIID_PlaceFloating(FIID_Ghost, HostGeo.AbsoluteToLocal(Center), BaseSize, Scale);

		// The shadow sits a little lower-right and grows with the lift.
		FIID_PlaceFloating(FIID_Shadow, HostGeo.AbsoluteToLocal(Center + FVector2D(ShadowPx, ShadowPx)), BaseSize, Scale);
	}

	/**
	 * Places a floating image. Its slot stays at the top-left corner with a fixed size and it is
	 * moved / scaled with its render transform only, so it never changes the size of any panel
	 * (moving the slot made the game's panel grow and stretched its dark background).
	 */
	void FIID_PlaceFloating(UImage Img, FVector2D LocalCenter, FVector2D BaseSize, float64 Scale)
	{
		if (!IsValid(Img))
			return;
		UCanvasPanelSlot ImgSlot = Cast<UCanvasPanelSlot>(Img.Slot);
		if (!IsValid(ImgSlot))
			return;
		ImgSlot.SetPosition(FVector2D(0.0, 0.0));
		ImgSlot.SetSize(BaseSize);
		Img.SetRenderTransformPivot(FVector2D(0.5, 0.5));
		Img.SetRenderTranslation(LocalCenter - BaseSize * 0.5);
		Img.SetRenderScale(FVector2D(Scale, Scale));
	}

	// Release outside the tiles (this layer is only hit-testable while dragging).
	UFUNCTION(BlueprintOverride)
	FEventReply OnMouseButtonUp(FGeometry MyGeometry, FPointerEvent MouseEvent)
	{
		if (!FIID_bPressing)
			return Widget::Unhandled();
		if (MouseEvent.GetEffectingButton() == EKeys::LeftMouseButton)
			FIID_Release(false);
		return Widget::Handled();
	}

	UFUNCTION(BlueprintOverride)
	FEventReply OnMouseButtonDown(FGeometry MyGeometry, FPointerEvent MouseEvent)
	{
		if (FIID_bDragging)
		{
			FIID_Cancel("cancelled");
			return Widget::Handled();
		}
		return Widget::Unhandled();
	}

	// ------------------------------------------------------------------
	//  The order
	// ------------------------------------------------------------------

	/** "name|value" of a grid item, or "" for empty / unknown slots. */
	FString FIID_KeyOf(UObject Obj)
	{
		UInventorySlotData Data = Cast<UInventorySlotData>(Obj);
		if (!IsValid(Data) || Data.m_IsEmpty)
			return "";
		FString ItemName = Data.m_Name.ToString();
		if (ItemName.IsEmpty())
			return "";
		return f"{ItemName}|{Data.m_Value}";
	}

	/** "name|value" part of a numbered key ("name|value#3" -> "name|value"). */
	FString FIID_BaseKey(FString Key)
	{
		FString Left;
		FString Right;
		if (Key.Split("#", Left, Right, ESearchCase::CaseSensitive, ESearchDir::FromEnd))
			return Left;
		return Key;
	}

	/**
	 * Renumbers identical items in the saved order from top to bottom (#0 = first, #1 = second ...).
	 * The grid always counts identical items from top to bottom too, so after this the number of
	 * an item on screen always points at its own place in the order (otherwise, after moving one
	 * copy past another, a drag could swap the wrong tile).
	 */
	void FIID_NormalizeOrder()
	{
		if (!IsValid(FIID_Save))
			return;
		TMap<FString, int> Seen;
		for (int i = 0; i < FIID_Save.Order.Num(); i++)
		{
			FString BaseKey = FIID_BaseKey(FIID_Save.Order[i]);
			int Count = 0;
			if (!Seen.Find(BaseKey, Count))
				Count = 0;
			FIID_Save.Order[i] = f"{BaseKey}#{Count}";
			Seen.Add(BaseKey, Count + 1);
		}
	}

	/**
	 * Keys for a whole list: identical items get a running number ("name|value#0", "#1" ...),
	 * so each copy has its own place in the order. "" for empty / unknown slots.
	 */
	TArray<FString> FIID_KeysOf(TArray<UObject> Items)
	{
		TArray<FString> Keys;
		TMap<FString, int> Seen;
		for (int i = 0; i < Items.Num(); i++)
		{
			FString BaseKey = FIID_KeyOf(Items[i]);
			if (BaseKey == "")
			{
				Keys.Add("");
				continue;
			}
			int Count = 0;
			if (!Seen.Find(BaseKey, Count))
				Count = 0;
			Keys.Add(f"{BaseKey}#{Count}");
			Seen.Add(BaseKey, Count + 1);
		}
		return Keys;
	}

	/** The numbered key of one item as it sits in the grid right now. */
	FString FIID_GridKeyOf(UObject Obj)
	{
		if (!IsValid(FIID_Grid))
			return "";
		TArray<UObject> Items = FIID_Grid.GetListItems();
		int Index = Items.FindIndex(Obj);
		if (Index < 0)
			return "";
		TArray<FString> Keys = FIID_KeysOf(Items);
		return Keys[Index];
	}

	/** Puts the grid's items into the saved order whenever the game has refilled the grid. */
	void FIID_ApplyOrder()
	{
		TArray<UObject> Items = FIID_Grid.GetListItems();
		if (FIID_SameList(Items, FIID_LastApplied))
			return;

		// Rank of every item in the saved order (unknown items are added at the end).
		bool bAddedKeys = false;
		TArray<int> Ranks;
		TArray<FString> ItemKeys = FIID_KeysOf(Items);
		for (int i = 0; i < Items.Num(); i++)
		{
			FString Key = ItemKeys[i];
			int Rank = 1000000 + i;
			if (Key != "")
			{
				Rank = FIID_Save.Order.FindIndex(Key);
				if (Rank < 0)
				{
					FIID_Save.Order.Add(Key);
					Rank = FIID_Save.Order.Num() - 1;
					bAddedKeys = true;
				}
			}
			Ranks.Add(Rank);
		}

		// Stable insertion sort by rank.
		TArray<UObject> Sorted = Items;
		TArray<int> SortedRanks = Ranks;
		for (int i = 1; i < Sorted.Num(); i++)
		{
			UObject Obj = Sorted[i];
			int R = SortedRanks[i];
			int j = i - 1;
			while (j >= 0 && SortedRanks[j] > R)
			{
				Sorted[j + 1] = Sorted[j];
				SortedRanks[j + 1] = SortedRanks[j];
				j--;
			}
			Sorted[j + 1] = Obj;
			SortedRanks[j + 1] = R;
		}

		if (!FIID_SameList(Sorted, Items))
		{
			// Setting the list scrolls the grid back to the top: keep the scroll position.
			int KeepOffset = FIID_Grid.GetCurrentScrollOffset();
			FIID_Grid.SetListItemsBP(Sorted, true);
			FIID_Grid.SetScrollOffset(KeepOffset);
			FIID_KeepScrollOffset = KeepOffset;
			FIID_KeepScrollFrames = 12;   // the grid may only rebuild a frame later
			FIID_Reorders++;
			FIID_LastAction = f"grid put into the saved order ({Sorted.Num()} items)";
		}
		FIID_LastApplied = Sorted;

		if (bAddedKeys)
		{
			FIID_NormalizeOrder();
			FIID_SaveOrder();
		}
	}

	/**
	 * The Sort button (part 1) has put the grid into a new order: that order becomes
	 * the saved order. Items not in the grid right now keep their old places after it.
	 */
	void FIID_AdoptGridOrder()
	{
		if (!IsValid(FIID_Grid) || !IsValid(FIID_Save))
			return;
		if (FIID_bPressing || FIID_bDragging)
			FIID_EndDrag();

		TArray<UObject> Items = FIID_Grid.GetListItems();
		TArray<FString> ItemKeys = FIID_KeysOf(Items);
		TArray<FString> NewOrder;
		for (int i = 0; i < Items.Num(); i++)
		{
			FString Key = ItemKeys[i];
			if (Key != "" && !NewOrder.Contains(Key))
				NewOrder.Add(Key);
		}
		for (int i = 0; i < FIID_Save.Order.Num(); i++)
		{
			if (!NewOrder.Contains(FIID_Save.Order[i]))
				NewOrder.Add(FIID_Save.Order[i]);
		}
		FIID_Save.Order = NewOrder;
		FIID_NormalizeOrder();
		FIID_SaveOrder();
		FIID_LastApplied = Items;   // the grid already shows this order
		FIID_Adopted++;
		FIID_LastAction = f"order taken over from the Sort button ({Items.Num()} items)";
	}

	void FIID_Swap(UObject A, UObject B)
	{
		FString KeyA = FIID_GridKeyOf(A);
		FString KeyB = FIID_GridKeyOf(B);
		int IndexA = FIID_Save.Order.FindIndex(KeyA);
		int IndexB = FIID_Save.Order.FindIndex(KeyB);
		if (KeyA == "" || KeyB == "" || IndexA < 0 || IndexB < 0)
		{
			FIID_LastAction = f"swap failed: {KeyA} / {KeyB} not in the order list";
			return;
		}
		FIID_Save.Order[IndexA] = KeyB;
		FIID_Save.Order[IndexB] = KeyA;
		FIID_NormalizeOrder();
		FIID_Swaps++;
		FIID_SaveOrder();

		FIID_LastApplied.Empty();   // re-sort right away
		FIID_ApplyOrder();
		FIID_LastAction = f"swapped {KeyA} <-> {KeyB}";
	}

	bool FIID_SameList(TArray<UObject> A, TArray<UObject> B)
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

	/** Working copy <- the order of the loaded game (empty for a new game or an old save). */
	void FIID_LoadOrder()
	{
		if (!IsValid(FIID_Save))
			FIID_Save = Cast<UFIID_OrderSave>(Gameplay::CreateSaveGameObject(UFIID_OrderSave));
		if (!IsValid(FIID_Save))
			return;
		if (IsValid(FIID_GameState))
			FIID_Save.Order = FIID_GameState.FIID_Order;
		else
			FIID_Save.Order.Empty();

		// Orders saved before v0.4.1 have keys without the running number: they become "#0".
		bool bChanged = false;
		for (int i = 0; i < FIID_Save.Order.Num(); i++)
		{
			if (!FIID_Save.Order[i].Contains("#"))
			{
				FIID_Save.Order[i] = FIID_Save.Order[i] + "#0";
				bChanged = true;
			}
		}
		FIID_NormalizeOrder();
		if (bChanged)
			FIID_SaveOrder();
	}

	/** Working copy -> the loaded game (written into the save file when the game is saved). */
	void FIID_SaveOrder()
	{
		if (IsValid(FIID_Save) && IsValid(FIID_GameState))
			FIID_GameState.FIID_Order = FIID_Save.Order;
	}

	// ------------------------------------------------------------------
	//  Dark background behind the grid
	// ------------------------------------------------------------------

	/**
	 * Finds the dark see-through background behind the item grid and makes it fully transparent.
	 * Looks at the panels around the grid (a few levels up): images next to the grid that are
	 * about as big as the grid are hidden, and borders around the grid get a transparent
	 * background (their content, the grid, stays visible). Stops before the panels get much
	 * bigger than the grid, so the inventory window itself is not touched.
	 */
	void FIID_HideGridBackdrop()
	{
		FVector2D GridSz = FIID_Grid.GetCachedGeometry().GetAbsoluteSize();
		float64 GridArea = GridSz.X * GridSz.Y;
		if (GridArea < 100.0)
			return;   // not drawn yet, try again next frame

		FIID_bBackdropDone = true;
		FString Hidden = "";

		// 1) Big images inside the grid widget itself (not inside the item tiles).
		TArray<UWidget> Inside;
		FIID_Collect(FIID_Grid.GetRootWidget(), Inside, 0);
		for (int i = 0; i < Inside.Num(); i++)
		{
			UImage InnerImg = Cast<UImage>(Inside[i]);
			if (!IsValid(InnerImg))
				continue;
			FVector2D InnerSz = InnerImg.GetCachedGeometry().GetAbsoluteSize();
			if (InnerSz.X * InnerSz.Y < GridArea * 0.6)
				continue;
			InnerImg.SetRenderOpacity(0.0);
			Hidden += f"image {InnerImg.GetName().ToString()} (in grid), ";
		}

		// 2) Panels around the grid.
		UWidget Cur = FIID_Grid;
		for (int Lvl = 0; Lvl < 6; Lvl++)
		{
			UPanelWidget P = Cur.GetParent();
			if (!IsValid(P))
				break;
			FVector2D PSz = P.GetCachedGeometry().GetAbsoluteSize();
			if (PSz.X * PSz.Y > GridArea * 1.8)
				break;

			UBorder AsBorder = Cast<UBorder>(P);
			if (IsValid(AsBorder))
			{
				AsBorder.SetBrushColor(FLinearColor(0.0, 0.0, 0.0, 0.0));
				Hidden += f"border {P.GetName().ToString()}, ";
			}

			for (int i = 0; i < P.GetChildrenCount(); i++)
			{
				UWidget Sibling = P.GetChildAt(i);
				if (!IsValid(Sibling) || Sibling == Cur)
					continue;
				UImage Img = Cast<UImage>(Sibling);
				if (!IsValid(Img))
					continue;
				FVector2D ImgSz = Img.GetCachedGeometry().GetAbsoluteSize();
				if (ImgSz.X * ImgSz.Y < GridArea * 0.6)
					continue;
				Img.SetRenderOpacity(0.0);
				Hidden += f"image {Img.GetName().ToString()}, ";
			}
			Cur = P;
		}
		FIID_BackdropInfo = Hidden == "" ? "nothing found next to the grid" : f"made transparent: {Hidden}";
	}

	// ------------------------------------------------------------------
	//  Debug output
	// ------------------------------------------------------------------

	void FIID_UpdateDebugText(FVector2D Mouse)
	{
		if (!IsValid(FIID_DebugText))
			return;

		int ListCount = IsValid(FIID_Grid) ? FIID_Grid.GetNumItems() : -1;
		int OrderCount = IsValid(FIID_Save) ? FIID_Save.Order.Num() : -1;
		FString S = "InventoryItemDrag debug";
		S += f"\ninventory {IsValid(FIID_Inv)}, grid {IsValid(FIID_Grid)}, items {ListCount}, saved order {OrderCount}";
		S += f"\ntiles with catcher {FIID_Catchers.Num()}, failures {FIID_InjectFailures}";
		S += f"\nhover [{FIID_HoverIndex}] {FIID_KeyOf(FIID_HoverItem)}";
		S += f"\npressing {FIID_bPressing}, dragging {FIID_bDragging}, from {FIID_KeyOf(FIID_SrcItem)}";
		S += f"\nmouse ({Mouse.X}, {Mouse.Y}), over a tile {FIID_IsOverCatcher(Mouse)}";
		int ScrollNow = IsValid(FIID_Grid) ? FIID_Grid.GetCurrentScrollOffset() : -1;
		S += f"\nreorders {FIID_Reorders}, swaps {FIID_Swaps}, sorts taken over {FIID_Adopted}, scroll row {ScrollNow} (kept {FIID_KeepScrollOffset})";
		S += f"\ndragged copy: {FIID_GhostInfo}, shown {IsValid(FIID_Ghost) && FIID_Ghost.IsVisible()}";
		S += f"\nscreen panel: {FIID_HostInfo}";
		S += f"\ngrid background: {FIID_BackdropInfo}";
		S += f"\ntile images: {FIID_TileImages}";
		S += f"\nlast: {FIID_LastAction}";
		for (int i = 0; i < FIID_EntryRootClasses.Num() && i < 4; i++)
			S += f"\ntile: {FIID_EntryRootClasses[i]}";
		FIID_DebugText.SetText(FText::FromString(S));
	}
}


// -------------------------------------------------------------------------------------
//  Helpers
// -------------------------------------------------------------------------------------

/**
 * The panel our own canvas goes into. First choice: the biggest canvas panel ABOVE the
 * inventory (the screens that contain it, ideally the full-screen HUD canvas). A canvas does not
 * resize itself to its content. Fallback: the biggest canvas / overlay inside the inventory.
 */
UPanelWidget FIID_FindHostPanel(UUserWidget Base)
{
	UPanelWidget Above = FIID_FindCanvasAbove(Base);
	if (IsValid(Above))
		return Above;
	return FIID_FindPanelInside(Base);
}

UPanelWidget FIID_FindCanvasAbove(UUserWidget Base)
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

		// Top of this widget's tree: continue in the user widget that owns the tree.
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

/** The biggest canvas or overlay inside the inventory screen. */
UPanelWidget FIID_FindPanelInside(UUserWidget Base)
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
		if (W.GetName().ToString().StartsWith("FIID_"))
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
void FIID_AddFullSize(UPanelWidget Host, UWidget Child, int ZOrder)
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

/** An image on our canvas that floats above everything (moved with its render transform). */
UImage FIID_MakeFloatingImage(UUserWidget Base, UCanvasPanel Canvas, FName WidgetName, int ZOrder)
{
	UImage Img = Cast<UImage>(Base.ConstructWidget(UImage, WidgetName));
	if (!IsValid(Img))
		return nullptr;
	UCanvasPanelSlot ImgSlot = Canvas.AddChildToCanvas(Img);
	if (IsValid(ImgSlot))
	{
		ImgSlot.SetAutoSize(false);
		ImgSlot.SetAlignment(FVector2D(0.0, 0.0));
		ImgSlot.SetPosition(FVector2D(0.0, 0.0));
		ImgSlot.SetSize(FVector2D(64.0, 64.0));
		ImgSlot.SetZOrder(ZOrder);
	}
	Img.SetVisibility(ESlateVisibility::Collapsed);
	return Img;
}

/** Walks the widget tree ourselves, including the inside of nested user widgets. */
void FIID_Collect(UWidget W, TArray<UWidget>& Out, int Depth)
{
	if (!IsValid(W) || Depth > 30)
		return;
	if (Out.Contains(W))
		return;
	Out.Add(W);

	UUserWidget AsUserWidget = Cast<UUserWidget>(W);
	if (IsValid(AsUserWidget))
		FIID_Collect(AsUserWidget.GetRootWidget(), Out, Depth + 1);

	UPanelWidget AsPanel = Cast<UPanelWidget>(W);
	if (IsValid(AsPanel))
	{
		for (int i = 0; i < AsPanel.GetChildrenCount(); i++)
			FIID_Collect(AsPanel.GetChildAt(i), Out, Depth + 1);
	}
}

/** True if the absolute point P lies inside widget W. */
bool FIID_Contains(UWidget W, FVector2D P)
{
	FGeometry G = W.GetCachedGeometry();
	FVector2D Sz = G.GetLocalSize();
	if (Sz.X <= 0.0 || Sz.Y <= 0.0)
		return false;
	FVector2D TopLeft = G.LocalToAbsolute(FVector2D(0.0, 0.0));
	FVector2D BottomRight = G.LocalToAbsolute(Sz);
	return P.X >= TopLeft.X && P.X <= BottomRight.X && P.Y >= TopLeft.Y && P.Y <= BottomRight.Y;
}

float64 FIID_Dist(FVector2D A, FVector2D B)
{
	float64 Dx = A.X - B.X;
	float64 Dy = A.Y - B.Y;
	return Math::Sqrt(Dx * Dx + Dy * Dy);
}
