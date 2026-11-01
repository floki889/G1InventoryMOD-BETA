// =====================================================================================
//  Improved Inventory - part 3: "Stack all items"
//  (mod F-ImprovedInventory 1.3.6; part 1 = ImprovedInventory_Sorting.as, part 2 = ImprovedInventory_ItemDrag.as)
//
//  The game splits big amounts into stacks of at most 99 (the item's m_MaxStack, which
//  scripts cannot change). With "Stack all items" switched on, every item is shown ONCE on
//  the grid with its full amount (e.g. 250 arrows): the extra stacks are hidden from the grid
//  and the amount number of the shown tile is replaced by the total. The game still keeps its
//  stacks underneath; using / dropping takes from the shown stack, and when it runs out the
//  next one takes its place, so the total keeps counting down correctly.
//
//  - Switched on / off in the Sort button's right-click menu (entry 3) and APPLY.
//  - Kept PER SAVE GAME (UFIST_StackState goes into the game's save), independent of the
//    sort mode: Categories / Values sorting keep the stacks merged.
//  - Same item = same name + value + hotbar number + inventory place, so an equipped / worn
//    item never merges with spare copies.
// =====================================================================================


/** "Stack all items" of the loaded game. Its SaveGame property goes into the game's save. */
class UFIST_StackState : UGothicModExt_WorldSubsystem
{
	UPROPERTY(SaveGame)
	bool FIST_bStackAll = false;

	// Not saved: merging paused for a moment (part 2 needs the game's own order to drop an item).
	bool FIST_bPaused = false;

	UFUNCTION(BlueprintOverride)
	void HandleNewGameStarted()
	{
		FIST_bStackAll = false;
	}
}

/** Is "Stack all items" on in the loaded game? */
bool FIST_IsStackingOn()
{
	UFIST_StackState State = UFIST_StackState::Get();
	return IsValid(State) && State.FIST_bStackAll;
}

/** Pauses / resumes merging (the grid then shows all the game's stacks for that moment). */
void FIST_PauseMerging(bool bPause)
{
	UFIST_StackState State = UFIST_StackState::Get();
	if (IsValid(State))
		State.FIST_bPaused = bPause;
}

bool FIST_IsMergingPaused()
{
	UFIST_StackState State = UFIST_StackState::Get();
	return IsValid(State) && State.FIST_bPaused;
}

/** Switches "Stack all items" on / off for the loaded game (kept when the game is saved). */
void FIST_SetStacking(bool bOn)
{
	UFIST_StackState State = UFIST_StackState::Get();
	if (IsValid(State))
		State.FIST_bStackAll = bOn;
}


/**
 * Does the merging on the inventory grid. Owned by the Sort button's layer (part 1), which calls
 * FIST_Update() every frame while the inventory is drawn.
 */
class UFIST_Stacker : UObject
{
	UInventoryMain FIST_Inv;
	UDiscreteItemViewWidget FIST_Grid;
	UTileView FIST_Tiles;
	bool FIST_bBound = false;

	bool FIST_bWasOn = false;
	TArray<UObject> FIST_LastApplied;     // the merged list we set last

	// Merged tiles: shown item -> total amount (and its own amount when merged, to notice changes).
	TMap<UObject, int> FIST_Totals;
	TMap<UObject, int> FIST_OwnAmount;

	// Which item each tile shows (from the tile view's "entry initialized" event).
	TMap<UUserWidget, UObject> FIST_EntryItem;
	TMap<UUserWidget, UTextBlock> FIST_EntryAmountText;

	// Widgets we made visible to show a total (e.g. merged single items whose amount box is hidden).
	TArray<UWidget> FIST_Forced;
	TArray<UUserWidget> FIST_ForcedEntry;
	TArray<UUserWidget> FIST_WrittenEntries;   // tiles whose amount text we replaced

	int FIST_KeepScrollOffset = 0;
	int FIST_KeepScrollFrames = 0;
	int64 FIST_NextRefresh = 0;

	FString FIST_Info = "";

	void FIST_Update(UInventoryMain Inv, UDiscreteItemViewWidget Grid, int64 NowTicks)
	{
		if (!IsValid(Inv) || !IsValid(Grid))
			return;
		FIST_Inv = Inv;
		if (Grid != FIST_Grid)
		{
			FIST_Grid = Grid;
			FIST_bBound = false;
			FIST_LastApplied.Empty();
		}
		FIST_Bind();

		bool bOn = FIST_IsStackingOn();
		if (FIST_IsMergingPaused())
		{
			// Part 2 is dropping an item: leave the grid in the game's order for now.
			FIST_LastApplied.Empty();
		}
		else if (bOn)
			FIST_Merge(NowTicks);
		else if (FIST_bWasOn)
		{
			// Switched off: the game fills the grid again with all its stacks.
			FIST_Totals.Empty();
			FIST_OwnAmount.Empty();
			FIST_LastApplied.Empty();
			FIST_Inv.RefreshInventory(true);
			FIST_Info = "stacking off: grid refilled";
		}
		FIST_bWasOn = bOn;

		// Merging sets a new list, which scrolls the grid to the top: hold the row for a moment.
		if (FIST_KeepScrollFrames > 0)
		{
			FIST_KeepScrollFrames--;
			if (FIST_Grid.GetCurrentScrollOffset() != FIST_KeepScrollOffset)
				FIST_Grid.SetScrollOffset(FIST_KeepScrollOffset);
		}

		FIST_UpdateAmountTexts();
	}

	/** Listens to the tile view, so we know which item each tile shows. */
	void FIST_Bind()
	{
		if (FIST_bBound || !IsValid(FIST_Grid))
			return;
		FIST_Tiles = FIST_Grid.TileView_Grid;
		if (!IsValid(FIST_Tiles))
			return;
		FIST_Tiles.BP_OnEntryInitialized.AddUFunction(this, n"FIST_OnEntryInitialized");
		FIST_bBound = true;
		FIST_EntryItem.Empty();
		// The tiles already on screen were set up before we listened: build them again.
		FIST_Tiles.RegenerateAllEntries();
	}

	UFUNCTION()
	private void FIST_OnEntryInitialized(UObject Item, UUserWidget Widget)
	{
		if (IsValid(Widget))
			FIST_EntryItem.Add(Widget, Item);
	}

	// ------------------------------------------------------------------
	//  Merging the list
	// ------------------------------------------------------------------

	/** Key of one grid item: same key = same item that may be merged. "" = never merged. */
	FString FIST_KeyOf(UObject Obj)
	{
		UInventorySlotData Data = Cast<UInventorySlotData>(Obj);
		if (!IsValid(Data) || Data.m_IsEmpty)
			return "";
		FString ItemName = Data.m_Name.ToString();
		if (ItemName.IsEmpty())
			return "";
		int InvType = int(Data.m_InventoryType);
		return f"{ItemName}|{Data.m_Value}|{Data.m_Hotkey}|{InvType}";
	}

	int FIST_AmountOf(UObject Obj)
	{
		UInventorySlotData Data = Cast<UInventorySlotData>(Obj);
		if (!IsValid(Data))
			return 0;
		return Data.m_Amount > 0 ? Data.m_Amount : 1;
	}

	void FIST_Merge(int64 NowTicks)
	{
		TArray<UObject> Items = FIST_Grid.GetListItems();

		// A merged tile whose own amount changed (used / dropped) while its hidden stacks are not
		// on the grid: ask the game to fill the grid again, then merge again with fresh numbers.
		if (FIST_SameList(Items, FIST_LastApplied))
		{
			for (int i = 0; i < Items.Num(); i++)
			{
				int Own = 0;
				if (FIST_OwnAmount.Find(Items[i], Own) && Own != FIST_AmountOf(Items[i]) && NowTicks >= FIST_NextRefresh)
				{
					FIST_NextRefresh = NowTicks + 5000000;   // at most every 0.5 s
					FIST_LastApplied.Empty();
					FIST_Inv.RefreshInventory(true);
					FIST_Info = "amount changed: grid refilled";
					return;
				}
			}
			return;
		}

		// Group identical items; the first one of each group stays on the grid.
		TArray<UObject> Merged;
		TArray<FString> MergedKeys;
		TArray<int> Totals;
		TArray<int> Members;
		bool bHasDuplicates = false;
		for (int i = 0; i < Items.Num(); i++)
		{
			FString Key = FIST_KeyOf(Items[i]);
			int Index = Key.IsEmpty() ? -1 : MergedKeys.FindIndex(Key);
			if (Index >= 0)
			{
				Totals[Index] = Totals[Index] + FIST_AmountOf(Items[i]);
				Members[Index] = Members[Index] + 1;
				bHasDuplicates = true;
				continue;
			}
			Merged.Add(Items[i]);
			MergedKeys.Add(Key);
			Totals.Add(FIST_AmountOf(Items[i]));
			Members.Add(1);
		}

		if (!bHasDuplicates)
		{
			// Same items in another order (sorting / dragging), or nothing to merge: keep the
			// totals of the tiles that are still there and unchanged.
			TMap<UObject, int> KeptTotals;
			TMap<UObject, int> KeptOwn;
			for (int i = 0; i < Items.Num(); i++)
			{
				int Total = 0;
				int Own = 0;
				if (FIST_Totals.Find(Items[i], Total) && FIST_OwnAmount.Find(Items[i], Own) && Own == FIST_AmountOf(Items[i]))
				{
					KeptTotals.Add(Items[i], Total);
					KeptOwn.Add(Items[i], Own);
				}
			}
			FIST_Totals = KeptTotals;
			FIST_OwnAmount = KeptOwn;
			FIST_LastApplied = Items;
			return;
		}

		FIST_Totals.Empty();
		FIST_OwnAmount.Empty();
		for (int i = 0; i < Merged.Num(); i++)
		{
			if (Members[i] > 1)
			{
				FIST_Totals.Add(Merged[i], Totals[i]);
				FIST_OwnAmount.Add(Merged[i], FIST_AmountOf(Merged[i]));
			}
		}

		int KeepOffset = FIST_Grid.GetCurrentScrollOffset();
		FIST_Grid.SetListItemsBP(Merged, true);
		FIST_Grid.SetScrollOffset(KeepOffset);
		FIST_KeepScrollOffset = KeepOffset;
		FIST_KeepScrollFrames = 12;
		FIST_LastApplied = Merged;
		FIST_Info = f"merged {Items.Num()} tiles into {Merged.Num()}";
	}

	bool FIST_SameList(TArray<UObject> A, TArray<UObject> B)
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
	//  Amount numbers on the tiles
	// ------------------------------------------------------------------

	void FIST_UpdateAmountTexts()
	{
		if (!IsValid(FIST_Tiles))
			return;
		TArray<UUserWidget> Shown = FIST_Tiles.GetDisplayedEntryWidgets();
		for (int i = 0; i < Shown.Num(); i++)
		{
			UUserWidget Entry = Shown[i];
			if (!IsValid(Entry))
				continue;
			UObject Item = nullptr;
			if (!FIST_EntryItem.Find(Entry, Item) || !IsValid(Item))
				continue;

			int Total = 0;
			bool bMerged = FIST_Totals.Find(Item, Total);
			if (bMerged)
			{
				UTextBlock AmountText = FIST_FindAmountText(Entry, Item);
				if (!IsValid(AmountText))
					continue;
				FString Wanted = f"{Total}";
				if (AmountText.GetText().ToString() != Wanted)
					AmountText.SetText(FText::FromString(Wanted));
				if (!FIST_WrittenEntries.Contains(Entry))
					FIST_WrittenEntries.Add(Entry);
				FIST_MakeShown(Entry, AmountText);
			}
			else if (FIST_WrittenEntries.Contains(Entry))
			{
				// This tile showed a total before and now shows a normal item: give it its own number back.
				FIST_WrittenEntries.Remove(Entry);
				UTextBlock AmountText = nullptr;
				int Own = FIST_AmountOf(Item);
				if (FIST_EntryAmountText.Find(Entry, AmountText) && IsValid(AmountText))
					AmountText.SetText(FText::FromString(f"{Own}"));
				FIST_UnforceEntry(Entry, Own <= 1);
			}
		}
	}

	/** The amount number of a tile: a text named like an amount, else the text showing its amount. */
	UTextBlock FIST_FindAmountText(UUserWidget Entry, UObject Item)
	{
		UTextBlock Cached = nullptr;
		if (FIST_EntryAmountText.Find(Entry, Cached) && IsValid(Cached))
			return Cached;

		TArray<UWidget> All;
		FIST_Collect(Entry.GetRootWidget(), All, 0);
		UInventorySlotData Data = Cast<UInventorySlotData>(Item);
		FString OwnText = f"{FIST_AmountOf(Item)}";
		FString HotkeyText = IsValid(Data) ? Data.m_Hotkey : "";

		UTextBlock ByName = nullptr;
		UTextBlock ByValue = nullptr;
		for (int i = 0; i < All.Num(); i++)
		{
			UTextBlock T = Cast<UTextBlock>(All[i]);
			if (!IsValid(T))
				continue;
			FString TName = T.GetName().ToString();
			if (TName.Contains("Hotkey") || TName.Contains("Key"))
				continue;
			if (TName.Contains("Amount") || TName.Contains("Count") || TName.Contains("Quantity")
				|| TName.Contains("Stack") || TName.Contains("Number"))
			{
				ByName = T;
				break;
			}
			FString Shown = T.GetText().ToString().TrimStartAndEnd();
			if (!IsValid(ByValue) && Shown == OwnText && Shown != HotkeyText)
				ByValue = T;
		}
		UTextBlock Found = IsValid(ByName) ? ByName : ByValue;
		if (IsValid(Found))
			FIST_EntryAmountText.Add(Entry, Found);
		return Found;
	}

	/** Makes the amount text (and hidden boxes around it inside the tile) visible. */
	void FIST_MakeShown(UUserWidget Entry, UTextBlock AmountText)
	{
		UWidget Root = Entry.GetRootWidget();
		UWidget W = AmountText;
		for (int Depth = 0; Depth < 8 && IsValid(W); Depth++)
		{
			ESlateVisibility Vis = W.GetVisibility();
			if (Vis == ESlateVisibility::Collapsed || Vis == ESlateVisibility::Hidden)
			{
				W.SetVisibility(ESlateVisibility::HitTestInvisible);
				FIST_Forced.Add(W);
				FIST_ForcedEntry.Add(Entry);
			}
			if (W == Root)
				break;
			W = W.GetParent();
		}
		// A box picture behind the number (siblings of the text) was hidden too.
		UPanelWidget Box = AmountText.GetParent();
		if (IsValid(Box))
		{
			for (int c = 0; c < Box.GetChildrenCount(); c++)
			{
				UImage Img = Cast<UImage>(Box.GetChildAt(c));
				if (!IsValid(Img))
					continue;
				ESlateVisibility Vis = Img.GetVisibility();
				if (Vis == ESlateVisibility::Collapsed || Vis == ESlateVisibility::Hidden)
				{
					Img.SetVisibility(ESlateVisibility::HitTestInvisible);
					FIST_Forced.Add(Img);
					FIST_ForcedEntry.Add(Entry);
				}
			}
		}
	}

	/** Undoes FIST_MakeShown for a tile (hides again only when the item has no amount to show). */
	void FIST_UnforceEntry(UUserWidget Entry, bool bHide)
	{
		for (int i = FIST_ForcedEntry.Num() - 1; i >= 0; i--)
		{
			if (FIST_ForcedEntry[i] != Entry)
				continue;
			if (bHide && IsValid(FIST_Forced[i]))
				FIST_Forced[i].SetVisibility(ESlateVisibility::Collapsed);
			FIST_Forced.RemoveAt(i);
			FIST_ForcedEntry.RemoveAt(i);
		}
	}

	void FIST_Collect(UWidget W, TArray<UWidget>& Out, int Depth)
	{
		if (!IsValid(W) || Depth > 12)
			return;
		Out.Add(W);
		UUserWidget AsUser = Cast<UUserWidget>(W);
		if (IsValid(AsUser) && Depth > 0)
			FIST_Collect(AsUser.GetRootWidget(), Out, Depth + 1);
		UPanelWidget AsPanel = Cast<UPanelWidget>(W);
		if (IsValid(AsPanel))
		{
			for (int c = 0; c < AsPanel.GetChildrenCount(); c++)
				FIST_Collect(AsPanel.GetChildAt(c), Out, Depth + 1);
		}
	}
}
