package com.keepcooking.app.data;

import android.database.Cursor;
import android.os.CancellationSignal;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.room.CoroutinesRoom;
import androidx.room.EntityInsertionAdapter;
import androidx.room.RoomDatabase;
import androidx.room.RoomSQLiteQuery;
import androidx.room.util.CursorUtil;
import androidx.room.util.DBUtil;
import androidx.sqlite.db.SupportSQLiteStatement;
import java.lang.Class;
import java.lang.Double;
import java.lang.Exception;
import java.lang.Object;
import java.lang.Override;
import java.lang.String;
import java.lang.SuppressWarnings;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.concurrent.Callable;
import javax.annotation.processing.Generated;
import kotlin.Unit;
import kotlin.coroutines.Continuation;

@Generated("androidx.room.RoomProcessor")
@SuppressWarnings({"unchecked", "deprecation"})
public final class PlanDao_Impl implements PlanDao {
  private final RoomDatabase __db;

  private final EntityInsertionAdapter<PlanEntity> __insertionAdapterOfPlanEntity;

  public PlanDao_Impl(@NonNull final RoomDatabase __db) {
    this.__db = __db;
    this.__insertionAdapterOfPlanEntity = new EntityInsertionAdapter<PlanEntity>(__db) {
      @Override
      @NonNull
      protected String createQuery() {
        return "INSERT OR REPLACE INTO `plans` (`id`,`householdId`,`date`,`mealRaw`,`recipeId`,`note`,`servings`,`updatedAt`,`deviceId`,`deleted`) VALUES (?,?,?,?,?,?,?,?,?,?)";
      }

      @Override
      protected void bind(@NonNull final SupportSQLiteStatement statement,
          @NonNull final PlanEntity entity) {
        statement.bindString(1, entity.getId());
        statement.bindString(2, entity.getHouseholdId());
        statement.bindLong(3, entity.getDate());
        statement.bindString(4, entity.getMealRaw());
        if (entity.getRecipeId() == null) {
          statement.bindNull(5);
        } else {
          statement.bindString(5, entity.getRecipeId());
        }
        statement.bindString(6, entity.getNote());
        if (entity.getServings() == null) {
          statement.bindNull(7);
        } else {
          statement.bindDouble(7, entity.getServings());
        }
        statement.bindLong(8, entity.getUpdatedAt());
        statement.bindString(9, entity.getDeviceId());
        final int _tmp = entity.getDeleted() ? 1 : 0;
        statement.bindLong(10, _tmp);
      }
    };
  }

  @Override
  public Object upsertAll(final List<PlanEntity> rows,
      final Continuation<? super Unit> $completion) {
    return CoroutinesRoom.execute(__db, true, new Callable<Unit>() {
      @Override
      @NonNull
      public Unit call() throws Exception {
        __db.beginTransaction();
        try {
          __insertionAdapterOfPlanEntity.insert(rows);
          __db.setTransactionSuccessful();
          return Unit.INSTANCE;
        } finally {
          __db.endTransaction();
        }
      }
    }, $completion);
  }

  @Override
  public Object livePlans(final Continuation<? super List<PlanEntity>> $completion) {
    final String _sql = "SELECT * FROM plans WHERE deleted = 0 ORDER BY date ASC";
    final RoomSQLiteQuery _statement = RoomSQLiteQuery.acquire(_sql, 0);
    final CancellationSignal _cancellationSignal = DBUtil.createCancellationSignal();
    return CoroutinesRoom.execute(__db, false, _cancellationSignal, new Callable<List<PlanEntity>>() {
      @Override
      @NonNull
      public List<PlanEntity> call() throws Exception {
        final Cursor _cursor = DBUtil.query(__db, _statement, false, null);
        try {
          final int _cursorIndexOfId = CursorUtil.getColumnIndexOrThrow(_cursor, "id");
          final int _cursorIndexOfHouseholdId = CursorUtil.getColumnIndexOrThrow(_cursor, "householdId");
          final int _cursorIndexOfDate = CursorUtil.getColumnIndexOrThrow(_cursor, "date");
          final int _cursorIndexOfMealRaw = CursorUtil.getColumnIndexOrThrow(_cursor, "mealRaw");
          final int _cursorIndexOfRecipeId = CursorUtil.getColumnIndexOrThrow(_cursor, "recipeId");
          final int _cursorIndexOfNote = CursorUtil.getColumnIndexOrThrow(_cursor, "note");
          final int _cursorIndexOfServings = CursorUtil.getColumnIndexOrThrow(_cursor, "servings");
          final int _cursorIndexOfUpdatedAt = CursorUtil.getColumnIndexOrThrow(_cursor, "updatedAt");
          final int _cursorIndexOfDeviceId = CursorUtil.getColumnIndexOrThrow(_cursor, "deviceId");
          final int _cursorIndexOfDeleted = CursorUtil.getColumnIndexOrThrow(_cursor, "deleted");
          final List<PlanEntity> _result = new ArrayList<PlanEntity>(_cursor.getCount());
          while (_cursor.moveToNext()) {
            final PlanEntity _item;
            final String _tmpId;
            _tmpId = _cursor.getString(_cursorIndexOfId);
            final String _tmpHouseholdId;
            _tmpHouseholdId = _cursor.getString(_cursorIndexOfHouseholdId);
            final long _tmpDate;
            _tmpDate = _cursor.getLong(_cursorIndexOfDate);
            final String _tmpMealRaw;
            _tmpMealRaw = _cursor.getString(_cursorIndexOfMealRaw);
            final String _tmpRecipeId;
            if (_cursor.isNull(_cursorIndexOfRecipeId)) {
              _tmpRecipeId = null;
            } else {
              _tmpRecipeId = _cursor.getString(_cursorIndexOfRecipeId);
            }
            final String _tmpNote;
            _tmpNote = _cursor.getString(_cursorIndexOfNote);
            final Double _tmpServings;
            if (_cursor.isNull(_cursorIndexOfServings)) {
              _tmpServings = null;
            } else {
              _tmpServings = _cursor.getDouble(_cursorIndexOfServings);
            }
            final long _tmpUpdatedAt;
            _tmpUpdatedAt = _cursor.getLong(_cursorIndexOfUpdatedAt);
            final String _tmpDeviceId;
            _tmpDeviceId = _cursor.getString(_cursorIndexOfDeviceId);
            final boolean _tmpDeleted;
            final int _tmp;
            _tmp = _cursor.getInt(_cursorIndexOfDeleted);
            _tmpDeleted = _tmp != 0;
            _item = new PlanEntity(_tmpId,_tmpHouseholdId,_tmpDate,_tmpMealRaw,_tmpRecipeId,_tmpNote,_tmpServings,_tmpUpdatedAt,_tmpDeviceId,_tmpDeleted);
            _result.add(_item);
          }
          return _result;
        } finally {
          _cursor.close();
          _statement.release();
        }
      }
    }, $completion);
  }

  @Override
  public Object byIdIncludingDeleted(final String id,
      final Continuation<? super PlanEntity> $completion) {
    final String _sql = "SELECT * FROM plans WHERE id = ? LIMIT 1";
    final RoomSQLiteQuery _statement = RoomSQLiteQuery.acquire(_sql, 1);
    int _argIndex = 1;
    _statement.bindString(_argIndex, id);
    final CancellationSignal _cancellationSignal = DBUtil.createCancellationSignal();
    return CoroutinesRoom.execute(__db, false, _cancellationSignal, new Callable<PlanEntity>() {
      @Override
      @Nullable
      public PlanEntity call() throws Exception {
        final Cursor _cursor = DBUtil.query(__db, _statement, false, null);
        try {
          final int _cursorIndexOfId = CursorUtil.getColumnIndexOrThrow(_cursor, "id");
          final int _cursorIndexOfHouseholdId = CursorUtil.getColumnIndexOrThrow(_cursor, "householdId");
          final int _cursorIndexOfDate = CursorUtil.getColumnIndexOrThrow(_cursor, "date");
          final int _cursorIndexOfMealRaw = CursorUtil.getColumnIndexOrThrow(_cursor, "mealRaw");
          final int _cursorIndexOfRecipeId = CursorUtil.getColumnIndexOrThrow(_cursor, "recipeId");
          final int _cursorIndexOfNote = CursorUtil.getColumnIndexOrThrow(_cursor, "note");
          final int _cursorIndexOfServings = CursorUtil.getColumnIndexOrThrow(_cursor, "servings");
          final int _cursorIndexOfUpdatedAt = CursorUtil.getColumnIndexOrThrow(_cursor, "updatedAt");
          final int _cursorIndexOfDeviceId = CursorUtil.getColumnIndexOrThrow(_cursor, "deviceId");
          final int _cursorIndexOfDeleted = CursorUtil.getColumnIndexOrThrow(_cursor, "deleted");
          final PlanEntity _result;
          if (_cursor.moveToFirst()) {
            final String _tmpId;
            _tmpId = _cursor.getString(_cursorIndexOfId);
            final String _tmpHouseholdId;
            _tmpHouseholdId = _cursor.getString(_cursorIndexOfHouseholdId);
            final long _tmpDate;
            _tmpDate = _cursor.getLong(_cursorIndexOfDate);
            final String _tmpMealRaw;
            _tmpMealRaw = _cursor.getString(_cursorIndexOfMealRaw);
            final String _tmpRecipeId;
            if (_cursor.isNull(_cursorIndexOfRecipeId)) {
              _tmpRecipeId = null;
            } else {
              _tmpRecipeId = _cursor.getString(_cursorIndexOfRecipeId);
            }
            final String _tmpNote;
            _tmpNote = _cursor.getString(_cursorIndexOfNote);
            final Double _tmpServings;
            if (_cursor.isNull(_cursorIndexOfServings)) {
              _tmpServings = null;
            } else {
              _tmpServings = _cursor.getDouble(_cursorIndexOfServings);
            }
            final long _tmpUpdatedAt;
            _tmpUpdatedAt = _cursor.getLong(_cursorIndexOfUpdatedAt);
            final String _tmpDeviceId;
            _tmpDeviceId = _cursor.getString(_cursorIndexOfDeviceId);
            final boolean _tmpDeleted;
            final int _tmp;
            _tmp = _cursor.getInt(_cursorIndexOfDeleted);
            _tmpDeleted = _tmp != 0;
            _result = new PlanEntity(_tmpId,_tmpHouseholdId,_tmpDate,_tmpMealRaw,_tmpRecipeId,_tmpNote,_tmpServings,_tmpUpdatedAt,_tmpDeviceId,_tmpDeleted);
          } else {
            _result = null;
          }
          return _result;
        } finally {
          _cursor.close();
          _statement.release();
        }
      }
    }, $completion);
  }

  @NonNull
  public static List<Class<?>> getRequiredConverters() {
    return Collections.emptyList();
  }
}
