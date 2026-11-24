package com.keepcooking.app.data;

import android.database.Cursor;
import android.os.CancellationSignal;
import androidx.annotation.NonNull;
import androidx.room.CoroutinesRoom;
import androidx.room.EntityInsertionAdapter;
import androidx.room.RoomDatabase;
import androidx.room.RoomSQLiteQuery;
import androidx.room.SharedSQLiteStatement;
import androidx.room.util.CursorUtil;
import androidx.room.util.DBUtil;
import androidx.sqlite.db.SupportSQLiteStatement;
import java.lang.Class;
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
public final class ListItemDao_Impl implements ListItemDao {
  private final RoomDatabase __db;

  private final EntityInsertionAdapter<ListItemEntity> __insertionAdapterOfListItemEntity;

  private final SharedSQLiteStatement __preparedStmtOfDeleteForList;

  public ListItemDao_Impl(@NonNull final RoomDatabase __db) {
    this.__db = __db;
    this.__insertionAdapterOfListItemEntity = new EntityInsertionAdapter<ListItemEntity>(__db) {
      @Override
      @NonNull
      protected String createQuery() {
        return "INSERT OR REPLACE INTO `list_items` (`id`,`listId`,`name`,`quantity`,`aisle`,`checked`,`recipeId`,`updatedAt`,`deviceId`,`deleted`) VALUES (?,?,?,?,?,?,?,?,?,?)";
      }

      @Override
      protected void bind(@NonNull final SupportSQLiteStatement statement,
          @NonNull final ListItemEntity entity) {
        statement.bindString(1, entity.getId());
        statement.bindString(2, entity.getListId());
        statement.bindString(3, entity.getName());
        statement.bindString(4, entity.getQuantity());
        statement.bindString(5, entity.getAisle());
        final int _tmp = entity.getChecked() ? 1 : 0;
        statement.bindLong(6, _tmp);
        if (entity.getRecipeId() == null) {
          statement.bindNull(7);
        } else {
          statement.bindString(7, entity.getRecipeId());
        }
        statement.bindLong(8, entity.getUpdatedAt());
        statement.bindString(9, entity.getDeviceId());
        final int _tmp_1 = entity.getDeleted() ? 1 : 0;
        statement.bindLong(10, _tmp_1);
      }
    };
    this.__preparedStmtOfDeleteForList = new SharedSQLiteStatement(__db) {
      @Override
      @NonNull
      public String createQuery() {
        final String _query = "DELETE FROM list_items WHERE listId = ?";
        return _query;
      }
    };
  }

  @Override
  public Object upsertAll(final List<ListItemEntity> rows,
      final Continuation<? super Unit> $completion) {
    return CoroutinesRoom.execute(__db, true, new Callable<Unit>() {
      @Override
      @NonNull
      public Unit call() throws Exception {
        __db.beginTransaction();
        try {
          __insertionAdapterOfListItemEntity.insert(rows);
          __db.setTransactionSuccessful();
          return Unit.INSTANCE;
        } finally {
          __db.endTransaction();
        }
      }
    }, $completion);
  }

  @Override
  public Object deleteForList(final String listId, final Continuation<? super Unit> $completion) {
    return CoroutinesRoom.execute(__db, true, new Callable<Unit>() {
      @Override
      @NonNull
      public Unit call() throws Exception {
        final SupportSQLiteStatement _stmt = __preparedStmtOfDeleteForList.acquire();
        int _argIndex = 1;
        _stmt.bindString(_argIndex, listId);
        try {
          __db.beginTransaction();
          try {
            _stmt.executeUpdateDelete();
            __db.setTransactionSuccessful();
            return Unit.INSTANCE;
          } finally {
            __db.endTransaction();
          }
        } finally {
          __preparedStmtOfDeleteForList.release(_stmt);
        }
      }
    }, $completion);
  }

  @Override
  public Object forList(final String listId,
      final Continuation<? super List<ListItemEntity>> $completion) {
    final String _sql = "SELECT * FROM list_items WHERE listId = ?";
    final RoomSQLiteQuery _statement = RoomSQLiteQuery.acquire(_sql, 1);
    int _argIndex = 1;
    _statement.bindString(_argIndex, listId);
    final CancellationSignal _cancellationSignal = DBUtil.createCancellationSignal();
    return CoroutinesRoom.execute(__db, false, _cancellationSignal, new Callable<List<ListItemEntity>>() {
      @Override
      @NonNull
      public List<ListItemEntity> call() throws Exception {
        final Cursor _cursor = DBUtil.query(__db, _statement, false, null);
        try {
          final int _cursorIndexOfId = CursorUtil.getColumnIndexOrThrow(_cursor, "id");
          final int _cursorIndexOfListId = CursorUtil.getColumnIndexOrThrow(_cursor, "listId");
          final int _cursorIndexOfName = CursorUtil.getColumnIndexOrThrow(_cursor, "name");
          final int _cursorIndexOfQuantity = CursorUtil.getColumnIndexOrThrow(_cursor, "quantity");
          final int _cursorIndexOfAisle = CursorUtil.getColumnIndexOrThrow(_cursor, "aisle");
          final int _cursorIndexOfChecked = CursorUtil.getColumnIndexOrThrow(_cursor, "checked");
          final int _cursorIndexOfRecipeId = CursorUtil.getColumnIndexOrThrow(_cursor, "recipeId");
          final int _cursorIndexOfUpdatedAt = CursorUtil.getColumnIndexOrThrow(_cursor, "updatedAt");
          final int _cursorIndexOfDeviceId = CursorUtil.getColumnIndexOrThrow(_cursor, "deviceId");
          final int _cursorIndexOfDeleted = CursorUtil.getColumnIndexOrThrow(_cursor, "deleted");
          final List<ListItemEntity> _result = new ArrayList<ListItemEntity>(_cursor.getCount());
          while (_cursor.moveToNext()) {
            final ListItemEntity _item;
            final String _tmpId;
            _tmpId = _cursor.getString(_cursorIndexOfId);
            final String _tmpListId;
            _tmpListId = _cursor.getString(_cursorIndexOfListId);
            final String _tmpName;
            _tmpName = _cursor.getString(_cursorIndexOfName);
            final String _tmpQuantity;
            _tmpQuantity = _cursor.getString(_cursorIndexOfQuantity);
            final String _tmpAisle;
            _tmpAisle = _cursor.getString(_cursorIndexOfAisle);
            final boolean _tmpChecked;
            final int _tmp;
            _tmp = _cursor.getInt(_cursorIndexOfChecked);
            _tmpChecked = _tmp != 0;
            final String _tmpRecipeId;
            if (_cursor.isNull(_cursorIndexOfRecipeId)) {
              _tmpRecipeId = null;
            } else {
              _tmpRecipeId = _cursor.getString(_cursorIndexOfRecipeId);
            }
            final long _tmpUpdatedAt;
            _tmpUpdatedAt = _cursor.getLong(_cursorIndexOfUpdatedAt);
            final String _tmpDeviceId;
            _tmpDeviceId = _cursor.getString(_cursorIndexOfDeviceId);
            final boolean _tmpDeleted;
            final int _tmp_1;
            _tmp_1 = _cursor.getInt(_cursorIndexOfDeleted);
            _tmpDeleted = _tmp_1 != 0;
            _item = new ListItemEntity(_tmpId,_tmpListId,_tmpName,_tmpQuantity,_tmpAisle,_tmpChecked,_tmpRecipeId,_tmpUpdatedAt,_tmpDeviceId,_tmpDeleted);
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

  @NonNull
  public static List<Class<?>> getRequiredConverters() {
    return Collections.emptyList();
  }
}
